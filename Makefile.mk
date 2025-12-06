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

# Boot Configuration Paths
BOOT_FIRMWARE_DIR ?= /boot/firmware
CONFIG_TXT ?= $(BOOT_FIRMWARE_DIR)/config.txt
CMDLINE_TXT ?= $(BOOT_FIRMWARE_DIR)/cmdline.txt
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
DEPS := git python3 python3-dev python3-venv python3-pip aircrack-ng libpcap-dev bettercap bettercap-caplets unzip ninja-build libglib2.0-dev libdbus-1-dev libjpeg-dev zlib1g-dev libpng-dev libfreetype-dev build-essential python3-dev libyaml-dev libssl-dev libffi-dev i2c-tools swig gpiod libgpiod-dev libgpiod-doc libcap-dev libopenblas-dev

# Use .DEFAULT_GOAL to make `help` the default action.
.DEFAULT_GOAL := help

# Phony targets don't represent files.
.PHONY: all install uninstall clean reinstall help \
		install-deps setup-swap setup-liblgpio setup-libpcap-compat setup-nexmon setup-monitor-service setup-bettercap setup-pwngrid setup-pwnagotchi setup-plugin-dirs setup-pwnagotchi-launcher setup-config setup-service setup-boot-config \
		uninstall-service uninstall-pwnagotchi restore-boot-config \
		start stop restart status logs verify-nexmon

##@ General

all: install ## Install Pwnagotchi and all its dependencies.
reinstall: uninstall install ## Uninstall and then reinstall Pwnagotchi.
clean: ## Remove local build artifacts and __pycache__ directories.
	@echo "Cleaning up local build artifacts..."
	-sudo rm -rf /tmp/pwngrid /tmp/gopacket-patched
	find . -type f -name "*.pyc" -delete
	find . -type d -name "__pycache__" -delete
	rm -rf .venv build dist *.egg-info

##@ Installation

install: install-deps setup-swap setup-liblgpio setup-libpcap-compat setup-nexmon setup-monitor-service setup-bettercap setup-pwngrid setup-pwnagotchi setup-plugin-dirs setup-pwnagotchi-launcher setup-config setup-service setup-boot-config ## Run the full installation process.
	@echo "\nPwnagotchi installation complete."
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
		echo "Swap file created and enabled."; \
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
		echo "liblgpio C library installed successfully."; \
	fi;

setup-nexmon:
	@echo "--> Installing Nexmon DKMS and creating FIXED wlan0mon glue script..."
	sudo apt-get update
	sudo apt-get install -y brcmfmac-nexmon-dkms firmware-nexmon
	@printf '%s\n' \
		'#!/bin/bash' \
		'set -e' \
		'echo "=== Setting up wlan0mon (Kali/Nexmon 2025 - FINAL & WORKING) ==="' \
		'if ip link show wlan0mon >/dev/null 2>&1 && ip link show wlan0mon | grep -qE "state (UP|UNKNOWN)"; then' \
		'    echo "wlan0mon already exists and is UP/UNKNOWN -> ready"' \
		'    touch /run/wlan0mon.ready 2>/dev/null || true' \
		'    exit 0' \
		'fi' \
		'echo "Cleaning old state..."' \
		'airmon-ng check kill >/dev/null 2>&1 || true' \
		'ip link delete wlan0mon 2>/dev/null || true' \
		'echo "Creating fresh monitor interface..."' \
		'airmon-ng start wlan0 >/dev/null 2>&1 || true' \
		'iw dev wlan0mon set type monitor 2>/dev/null || true' \
		'ip link set dev wlan0mon up 2>/dev/null || true' \
		'for i in {1..15}; do' \
		'    STATE=$(ip link show wlan0mon 2>/dev/null | grep -o "state [A-Z]*" || echo "")' \
		'    if [ "$$STATE" = "state UP" ] || [ "$$STATE" = "state UNKNOWN" ]; then' \
		'        echo "wlan0mon is UP and ready"' \
		'        touch /run/wlan0mon.ready' \
		'        exit 0' \
		'    fi' \
		'    sleep 1' \
		'done' \
		'echo "ERROR: wlan0mon failed after 15s"' \
		'exit 1' \
		| sudo tee /usr/local/sbin/setup-wlan0mon.sh > /dev/null
	sudo chmod +x /usr/local/sbin/setup-wlan0mon.sh
	@echo "Fixed Nexmon glue script installed."

setup-monitor-service:
	@echo "--> Installing dedicated monitor-mode.service (2025 Kali/Nexmon standard)"
	@printf '%s\n' \
		'[Unit]' \
		'Description=Pwnagotchi Monitor Mode Manager (wlan0mon)' \
		'After=network.target' \
		'Wants=network.target' \
		'Before=pwngrid-peer.service bettercap.service pwnagotchi.service' \
		'' \
		'[Service]' \
		'Type=oneshot' \
		'RemainAfterExit=yes' \
		'TimeoutStartSec=90' \
		'ExecStart=/usr/local/sbin/setup-wlan0mon.sh' \
		'Restart=on-failure' \
		'RestartSec=5' \
		'ExecStop=/usr/local/sbin/teardown-wlan0mon.sh' \
		'' \
		'[Install]' \
		'WantedBy=multi-user.target' \
		| sudo tee /etc/systemd/system/monitor-mode.service > /dev/null
	@printf '%s\n' \
		'#!/bin/bash' \
		'set -e' \
		'echo "Stopping monitor mode..."' \
		'if ip link show wlan0mon >/dev/null 2>&1; then' \
		'    echo "Removing wlan0mon..."' \
		'    sudo airmon-ng stop wlan0mon >/dev/null 2>&1 || true' \
		'    sudo ip link delete wlan0mon 2>/dev/null || true' \
		'fi' \
		'rm -f /run/wlan0mon.ready' \
		'echo "Monitor mode stopped."' \
		| sudo tee /usr/local/sbin/teardown-wlan0mon.sh > /dev/null
	@sudo chmod +x /usr/local/sbin/teardown-wlan0mon.sh
	@echo "--> Enabling and starting monitor-mode service..."
	-sudo systemctl daemon-reload
	-sudo systemctl enable --now monitor-mode.service
	@echo "monitor-mode.service installed and started."

setup-bettercap: install-deps
	@echo "--> Installing Bettercap from APT repository..."
	# This relies on the 'bettercap' package being in the DEPS list.
	# The install-deps target handles the installation.
	@echo "--> Creating a streamlined bettercap-launcher (pwnlib dependency removed)..."
	@printf '%s\n' \
		'#!/usr/bin/env bash' \
		'' \
		'# Simple, direct mode detection without pwnlib.' \
		'# The monitor interface (wlan0mon) is now created by the pwngrid-peer.service.' \
		'MODE="auto"' \
		'if [ -f /root/.pwnagotchi-manual ]; then' \
		'  MODE="manual"' \
		'elif [ -f /root/.pwnagotchi-auto ]; then' \
		'  MODE="auto"' \
		'# Fallback logic: if USB is connected, assume manual mode for interaction.' \
		'elif ip link show usb0 2>/dev/null | grep -q "state UP"; then' \
		'  MODE="manual"' \
		'else' \
		'  # Default to auto mode if no other indicators are found.' \
		'  MODE="auto"' \
		'fi' \
		'' \
		'echo "Starting bettercap in $${MODE} mode..."' \
		'exec /usr/bin/bettercap -no-colors -caplet "pwnagotchi-$${MODE}" -iface wlan0mon' \
		| sudo tee /usr/bin/bettercap-launcher > /dev/null
	sudo chmod +x /usr/bin/bettercap-launcher
	@echo "--> Creating wait script for bettercap service..."
	@printf '%s\n' \
		'#!/bin/bash' \
		'# This script waits for the wlan0mon interface to be ready.' \
		'while [ ! -f /run/wlan0mon.ready ]; do' \
		'    echo "[bettercap] waiting for wlan0mon to be ready..."' \
		'    sleep 1' \
		'done' \
		| sudo tee /usr/local/sbin/wait-for-wlan0mon.sh > /dev/null
	sudo chmod +x /usr/local/sbin/wait-for-wlan0mon.sh
	@printf '%s\n' \
		'[Unit]' \
		'Description=Bettercap service for Pwnagotchi' \
		'After=network-online.target monitor-mode.service' \
		'Requires=monitor-mode.service' \
		'' \
		'[Service]' \
		'Type=simple' \
		'ExecStart=/usr/bin/bettercap-launcher' \
		'Restart=always' \
		'RestartSec=30' \
		'' \
		'[Install]' \
		'WantedBy=multi-user.target' \
		| sudo tee /etc/systemd/system/bettercap.service > /dev/null
	sudo /usr/bin/bettercap -eval "caplets.update; ui.update; quit"
	@echo "--> Enabling bettercap service..."
	-sudo systemctl daemon-reload
	-sudo systemctl enable --now bettercap.service
	@echo "Bettercap installation and service setup complete."

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
		echo "libpcap 1.9.1 installed successfully."; \
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
	@printf '%s\n' \
		'module github.com/jayofelony/pwngrid' \
		'' \
		'go 1.22' \
		'' \
		'require (' \
		'	github.com/biezhi/gorm-paginator/pagination v0.0.0-20190124091837-7a5c8ed20334' \
		'	github.com/evilsocket/islazy v1.11.0' \
		'	github.com/go-chi/chi/v5 v5.1.0' \
		'	github.com/go-chi/cors v1.2.1' \
		'	github.com/golang-jwt/jwt/v5 v5.2.1' \
		'	github.com/gopacket/gopacket v1.2.0' \
		'	github.com/jinzhu/gorm v1.9.16' \
		'	github.com/joho/godotenv v1.5.1' \
		')' \
		'' \
		'require golang.org/x/sys v0.22.0 // indirect' \
		'' \
		'replace github.com/gopacket/gopacket => /tmp/gopacket-patched' \
		| sudo tee /tmp/pwngrid/go.mod > /dev/null

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

	@echo "   - Neutralizing ifconfig for pwngrid service..."
	@sudo mkdir -p /usr/local/share/fake-commands
	@printf '%s\n' \
		'#!/bin/sh' \
		'exit 0' \
		| sudo tee /usr/local/share/fake-commands/ifconfig > /dev/null
	@sudo chmod +x /usr/local/share/fake-commands/ifconfig

	@printf '%s\n' \
		'[Unit]' \
		'Description=pwngrid peer service' \
		'After=network-online.target monitor-mode.service' \
		'Requires=monitor-mode.service' \
		'' \
		'[Service]' \
		'Environment=LD_PRELOAD=/usr/local/lib/libpcap.so.1' \
		'Environment=LD_LIBRARY_PATH=/usr/local/lib' \
		'Type=simple' \
		'ExecStart=/usr/local/bin/pwngrid -keys /etc/pwnagotchi -peers /root/peers -address 127.0.0.1:8666 -client-token /root/.api-enrollment.json -wait -iface wlan0mon -log /var/log/pwngrid-peer.log' \
		'Restart=always' \
		'RestartSec=30' \
		'' \
		'[Install]' \
		'WantedBy=multi-user.target' \
		| sudo tee /etc/systemd/system/pwngrid-peer.service > /dev/null

	@echo "   - Removing obsolete pwngrid-wrapper..."
	@sudo rm -f /usr/local/sbin/wait-for-wlan0mon.sh
	@sudo rm -f /usr/local/share/fake-commands/ifconfig
	@sudo rm -f /usr/local/bin/pwngrid-wrapper

	@echo "   - Enabling and restarting pwngrid service..."
	sudo systemctl daemon-reload
	-sudo systemctl enable pwngrid-peer.service
	-sudo systemctl restart pwngrid-peer.service
	@echo "Pwngrid installation and service setup complete."

setup-pwnagotchi: install-deps setup-liblgpio
	@echo "--> Cloning Pwnagotchi repository to $(TMPDIR)/pwnagotchi..."
	sudo rm -rf $(TMPDIR)/pwnagotchi
	sudo git clone --branch $(PWNAGOTCHI_BRANCH) $(PWNAGOTCHI_REPO) $(TMPDIR)/pwnagotchi
	@echo "--> Patching default.toml to use current user's home directory..."
	@# Replace all instances of /home/pi with the dynamic APP_USER's home directory.
	sudo sed -i 's|/home/pi|/home/$(APP_USER)|g' $(TMPDIR)/pwnagotchi/pwnagotchi/defaults.toml
	@echo "--> Creating Python virtual environment at $(VENV_DIR)..."
	sudo mkdir -p $(VENV_DIR)
	sudo $(PYTHON_EXECUTABLE) -m venv $(VENV_DIR)
	@echo "--> Installing Pwnagotchi Python dependencies..."
	@# Upgrade pip first.
	sudo $(VENV_DIR)/bin/pip install --upgrade pip setuptools wheel
	@echo "--> Pre-installing wheels to avoid compilation on RPi..."
	@# Detect architecture to download the correct wheel. armv7l is 32-bit, aarch64 is 64-bit.
	@# This avoids memory/CPU exhaustion from compiling NumPy from source.
	@UNAME_M=$(shell uname -m); \
	if [ "$$UNAME_M" = "armv7l" ]; then \
		echo "    Pre-installing wheels for armv7l..."; \
		WHEELS_TO_INSTALL="numpy/numpy-2.3.5-cp313-cp313-linux_armv7l.whl pillow/pillow-11.3.0-cp313-cp313-linux_armv7l.whl cryptography/cryptography-45.0.7-cp313-abi3-linux_armv7l.whl spidev/spidev-3.5-cp313-cp313-linux_armv7l.whl"; \
		for wheel_path in $$WHEELS_TO_INSTALL; do \
			WHEEL_FILE=$$(basename $$wheel_path); \
			PACKAGE_NAME=$$(dirname $$wheel_path); \
			WHEEL_URL="https://www.piwheels.org/simple/$$PACKAGE_NAME/$$WHEEL_FILE"; \
			echo "    Downloading $$WHEEL_FILE..."; \
			if sudo wget -q $$WHEEL_URL -O "$(TMPDIR)/$$WHEEL_FILE"; then \
				sudo $(VENV_DIR)/bin/pip install "$(TMPDIR)/$$WHEEL_FILE"; \
				sudo rm "$(TMPDIR)/$$WHEEL_FILE"; \
			else \
				echo "Could not download $$WHEEL_FILE. Pip will try to build from source."; \
			fi; \
		done; \
	else \
		echo "    Architecture is not armv7l ($$UNAME_M), installing dependencies via standard pip."; \
		sudo $(VENV_DIR)/bin/pip install numpy; \
	fi

	@echo "--> Installing Pwnagotchi and its dependencies from the cloned repo..."
	sudo $(VENV_DIR)/bin/pip install $(TMPDIR)/pwnagotchi
	@echo "--> Setting ownership for virtual environment directory..."
	sudo chown -R $(APP_USER):$(APP_USER) $(VENV_DIR)
	@echo "--> Cleaning up temporary source directory..."
	cd /tmp && sudo rm -rf $(TMPDIR)/pwnagotchi
	@echo "Pwnagotchi application setup complete."

setup-plugin-dirs:
	@echo "--> Creating custom plugin directories..."
	sudo mkdir -p $(APP_DIR)/custom-plugins-local
	sudo mkdir -p /usr/local/share/pwnagotchi/custom-plugins
	sudo mkdir -p /usr/local/share/pwnagotchi/available-plugins
	@echo "--> Populating plugin directories from local source folders (if they exist)..."
	@if [ -d "custom-plugins" ]; then \
		echo "    - Found 'custom-plugins' folder, copying contents..."; \
		sudo rsync -a --delete custom-plugins/ /usr/local/share/pwnagotchi/custom-plugins/; \
	fi
	@if [ -d "available-plugins" ]; then \
		echo "    - Found 'available-plugins' folder, copying contents..."; \
		sudo rsync -a --delete available-plugins/ /usr/local/share/pwnagotchi/available-plugins/; \
	fi
	@if [ -d "custom-plugins-local" ]; then \
		echo "    - Found 'custom-plugins-local' folder, copying contents..."; \
		sudo rsync -a --delete custom-plugins-local/ $(APP_DIR)/custom-plugins-local/; \
	fi
	@echo "--> Setting ownership for plugin directories..."
	sudo chown -R $(APP_USER):$(APP_USER) $(APP_DIR)/custom-plugins-local
	sudo chown -R $(APP_USER):$(APP_USER) /usr/local/share/pwnagotchi
	@echo "Plugin directories created."

setup-config:
	@echo "--> Creating initial configuration directory and file..."
	sudo mkdir -p $(CONFIG_DIR)
	# This creates a blank config file to be edited by the user later
	sudo touch $(CONFIG_DIR)/$(CONFIG_FILE)
	@echo "Configuration file $(CONFIG_DIR)/$(CONFIG_FILE) created."

setup-pwnagotchi-launcher:
	@echo "--> Creating pwnagotchi-launcher that respects /root/.pwnagotchi-* files..."
	@printf '%s\n' \
		'#!/usr/bin/env bash' \
		'MODE="auto"' \
		'# Check for mode files and then remove them to prepare for the next command.' \
		'if [ -f /root/.pwnagotchi-manual ]; then' \
		'  MODE="manual"' \
		'  rm -f /root/.pwnagotchi-manual /root/.pwnagotchi-auto' \
		'elif [ -f /root/.pwnagotchi-auto ]; then' \
		'  MODE="auto"' \
		'  rm -f /root/.pwnagotchi-manual /root/.pwnagotchi-auto' \
		'# Fallback logic: if USB is connected, assume manual mode for interaction.' \
		'elif ip link show usb0 2>/dev/null | grep -q "state UP"; then' \
		'  MODE="manual"' \
		'fi' \
		'echo "Starting pwnagotchi in $${MODE} mode..."' \
		'if [ "$${MODE}" = "manual" ]; then' \
		'  exec $(VENV_DIR)/bin/python3 $(VENV_DIR)/bin/pwnagotchi --manual' \
		'else' \
		'  exec $(VENV_DIR)/bin/python3 $(VENV_DIR)/bin/pwnagotchi' \
		'fi' | sudo tee /usr/bin/pwnagotchi-launcher >/dev/null
	@sudo chmod +x /usr/bin/pwnagotchi-launcher
	@echo "pwnagotchi-launcher created."

setup-service:
	@echo "--> Creating pwnagotchi systemd service file..."
	@printf '%s\n' \
		'[Unit]' \
		'Description=Pwnagotchi deep reinforcement learning' \
		'After=network-online.target pwngrid-peer.service bettercap.service monitor-mode.service' \
		'Wants=pwngrid-peer.service bettercap.service monitor-mode.service' \
		'' \
		'[Service]' \
		'# Pwnagotchi must be run as root to access wifi/bettercap' \
		'User=root' \
		'Group=root' \
		'Type=simple' \
		'ExecStart=/usr/bin/pwnagotchi-launcher' \
		'Restart=always' \
		'RestartSec=30' \
		'' \
		'[Install]' \
		'WantedBy=multi-user.target' \
		| sudo tee /etc/systemd/system/$(PROJECT_NAME).service > /dev/null

	@echo "   - Enabling pwnagotchi service..."
	sudo systemctl daemon-reload
	sudo systemctl enable $(PROJECT_NAME).service
	@echo "Pwnagotchi service configuration complete."

restore-boot-config:
	@echo "--> Restoring original boot configuration files from backup..."
	@if [ -f "$(CONFIG_TXT).bak" ]; then \
		echo "    - Restoring $(CONFIG_TXT) from backup..."; \
		sudo mv -f $(CONFIG_TXT).bak $(CONFIG_TXT); \
	else \
		echo "    - No backup found for $(CONFIG_TXT). Skipping."; \
	fi
	@if [ -f "$(CMDLINE_TXT).bak" ]; then \
		echo "    - Restoring $(CMDLINE_TXT) from backup..."; \
		sudo mv -f $(CMDLINE_TXT).bak $(CMDLINE_TXT); \
	else \
		echo "    - No backup found for $(CMDLINE_TXT). Skipping."; \
	fi
	@echo "Boot file restoration complete. A reboot is recommended."

setup-boot-config:
	@echo "--> Configuring /boot/firmware/config.txt and cmdline.txt for Pwnagotchi hardware..."

	@echo "    - Updating $(CONFIG_TXT)..."
	@# Ensure SPI, I2C, DWC2 overlay, and UART are enabled in config.txt
	@# Use sed to uncomment if present, or append if not.
	@# dtparam=spi=on
	@echo "    - Backing up original boot files (if backups don't exist)..."
	@if [ ! -f "$(CONFIG_TXT).bak" ]; then \
		sudo cp $(CONFIG_TXT) $(CONFIG_TXT).bak; \
		echo "      - $(CONFIG_TXT) backed up to $(CONFIG_TXT).bak"; \
	else \
		echo "      - Backup for $(CONFIG_TXT) already exists. Skipping."; \
	fi
	@if [ ! -f "$(CMDLINE_TXT).bak" ]; then \
		sudo cp $(CMDLINE_TXT) $(CMDLINE_TXT).bak; \
		echo "      - $(CMDLINE_TXT) backed up to $(CMDLINE_TXT).bak"; \
	else \
		echo "      - Backup for $(CMDLINE_TXT) already exists. Skipping."; \
	fi
	sudo sed -i '/^#dtparam=spi=on/s/^#//' $(CONFIG_TXT)
	@grep -q '^dtparam=spi=on' $(CONFIG_TXT) || echo 'dtparam=spi=on' | sudo tee -a $(CONFIG_TXT) > /dev/null

	@# dtparam=i2c_arm=on
	sudo sed -i '/^#dtparam=i2c_arm=on/s/^#//' $(CONFIG_TXT)
	@grep -q '^dtparam=i2c_arm=on' $(CONFIG_TXT) || echo 'dtparam=i2c_arm=on' | sudo tee -a $(CONFIG_TXT) > /dev/null

	@# dtoverlay=dwc2
	sudo sed -i '/^#dtoverlay=dwc2/s/^#//' $(CONFIG_TXT)
	@grep -q '^dtoverlay=dwc2' $(CONFIG_TXT) || echo 'dtoverlay=dwc2' | sudo tee -a $(CONFIG_TXT) > /dev/null

	@# enable_uart=1
	sudo sed -i '/^#enable_uart=1/s/^#//' $(CONFIG_TXT)
	@grep -q '^enable_uart=1' $(CONFIG_TXT) || echo 'enable_uart=1' | sudo tee -a $(CONFIG_TXT) > /dev/null

	@echo "    - Updating $(CMDLINE_TXT)..."
	@# Ensure modules-load=dwc2,g_ether is present in cmdline.txt
	@# Read current cmdline.txt content
	CMDLINE_CONTENT=$$(sudo cat $(CMDLINE_TXT)); \
	if ! echo "$$CMDLINE_CONTENT" | grep -q 'modules-load=dwc2,g_ether'; then \
		echo "    Adding 'modules-load=dwc2,g_ether' to $(CMDLINE_TXT)..."; \
		sudo sed -i 's/$$/ modules-load=dwc2,g_ether/' $(CMDLINE_TXT); \
	else \
		echo "    'modules-load=dwc2,g_ether' already present in $(CMDLINE_TXT). Skipping."; \
	fi;
	@echo "Boot configuration update complete. A reboot is required for changes to take effect."

##@ Uninstallation

uninstall: uninstall-service uninstall-pwnagotchi restore-boot-config ## Run the full uninstallation process, including restoring boot files.

uninstall-service:
	@echo "--> Disabling and stopping all Pwnagotchi-related services..."
	-sudo systemctl stop $(PROJECT_NAME).service
	-sudo systemctl disable $(PROJECT_NAME).service
	-sudo systemctl stop pwngrid-peer.service
	-sudo systemctl disable pwngrid-peer.service
	-sudo systemctl stop bettercap.service
	-sudo systemctl disable bettercap.service
	-sudo systemctl stop monitor-mode.service
	-sudo systemctl disable monitor-mode.service
	-sudo rm /etc/systemd/system/$(PROJECT_NAME).service
	-sudo rm /etc/systemd/system/pwngrid-peer.service
	-sudo rm /etc/systemd/system/bettercap.service
	-sudo rm /etc/systemd/system/monitor-mode.service
	-sudo rm /usr/bin/bettercap-launcher
	-sudo rm /usr/bin/pwnagotchi-launcher
	-sudo systemctl daemon-reload || true

uninstall-pwnagotchi:
	@echo "--> Removing Pwnagotchi application, environment, and configuration files..."
	-sudo rm -rf $(VENV_DIR)
	-sudo rm -rf $(CONFIG_DIR)
	-sudo rm -rf $(APP_DIR)/custom-plugins-local
	-sudo rm -rf /usr/local/share/pwnagotchi
	@echo "Uninstallation complete. (Note: Bettercap/Nexmon drivers must be manually uninstalled if no longer needed.)"

##@ Service Control

start: ## Start only the main pwnagotchi systemd service.
	sudo systemctl start $(PROJECT_NAME).service

stop: ## Stop only the main pwnagotchi systemd service.
	-sudo systemctl stop $(PROJECT_NAME).service

restart: ## Restart only the main pwnagotchi systemd service.
	sudo systemctl restart $(PROJECT_NAME).service

start-all: ## Start all Pwnagotchi-related services in the correct order.
	@echo "--> Starting all Pwnagotchi services..."
	sudo systemctl start bettercap.service
	sudo systemctl start pwngrid-peer.service
	sudo systemctl start $(PROJECT_NAME).service

stop-all: ## Stop all Pwnagotchi-related services.
	@echo "--> Stopping all Pwnagotchi services..."
	-sudo systemctl stop $(PROJECT_NAME).service
	-sudo systemctl stop pwngrid-peer.service
	-sudo systemctl stop bettercap.service

status: ## Check the status of all Pwnagotchi-related services.
	@echo "--- Pwnagotchi Service Status ---"
	sudo systemctl status $(PROJECT_NAME).service || echo "Pwnagotchi service not found/active."
	@echo "\n--- Pwngrid Service Status ---"
	sudo systemctl status pwngrid-peer.service || echo "Pwngrid service not found/active."
	@echo "\n--- Bettercap Service Status ---"
	sudo systemctl status bettercap.service || echo "Bettercap service not found/active."
	@echo "\n--- Monitor Mode Service Status ---"
	sudo systemctl status monitor-mode.service || echo "Monitor Mode service not found/active."

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
		echo "wlan0mon interface not found. Cannot test injection."; \
		echo "   ... run 'sudo airmon-ng start wlan0' manually to resolve."; \
	fi

##@ Help

help: ## Show this help message.
	@echo "Usage: make <target>"
	@echo ""
	@grep -E '(^[a-zA-Z_-]+:.*##.*$$)|(^##@)' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*##"; print "Available targets:\n"} /^##@/ {print "\n" $$1 "\n"} /^[^#]/ {printf "  %-30s %s\n", $$1, $$2}'