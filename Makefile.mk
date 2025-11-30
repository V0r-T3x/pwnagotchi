# Makefile for Pwnagotchi on Kali Linux (RPi Zero 2 W)
# This Makefile automates the installation and setup of Pwnagotchi,
# including the Nexmon drivers for monitor mode.

# --- Configuration ---
# These variables can be overridden from the command line.

# Project Settings
PROJECT_NAME := pwnagotchi
APP_USER     ?= $(shell whoami)

# Directory Settings
APP_DIR      ?= /opt/$(PROJECT_NAME)
VENV_DIR     ?= $(APP_DIR)/venv
CONFIG_DIR   ?= /etc/$(PROJECT_NAME)

# Python Settings
PYTHON_EXECUTABLE ?= python3

# Pwnagotchi Settings
PWNAGOTCHI_REPO ?= https://github.com/V0r-T3x/pwnagotchi.git
PWNAGOTCHI_BRANCH ?= master
CONFIG_FILE ?= config.toml

# System dependencies for Pwnagotchi on Kali Linux.
DEPS := git python3 python3-dev python3-venv python3-pip aircrack-ng libpcap-dev \
		brcmfmac-nexmon-dkms firmware-nexmon

# Use .DEFAULT_GOAL to make `help` the default action.
.DEFAULT_GOAL := help

# Phony targets don't represent files.
.PHONY: all install uninstall clean reinstall help \
		install-deps setup-nexmon setup-pwnagotchi setup-config setup-service \
		uninstall-service uninstall-pwnagotchi \
		start stop restart status logs verify-nexmon

##@ General

all: install ## Install Pwnagotchi and all its dependencies.

reinstall: uninstall install ## Uninstall and then reinstall Pwnagotchi.

clean: ## Remove local build artifacts and __pycache__ directories.
	@echo "Cleaning up local build artifacts..."
	find . -type f -name "*.pyc" -delete
	find . -type d -name "__pycache__" -delete
	rm -rf .venv build dist *.egg-info

##@ Installation

install: setup-nexmon setup-pwnagotchi setup-config setup-service ## Run the full installation process.
	@echo "\n✅ Pwnagotchi installation complete."
	@echo "   A reboot is required to load the new drivers and start the service."
	@echo "   Run 'sudo reboot' to apply all changes."
	@echo "   After reboot, run 'make status' to check the service status."
	@echo "   Run 'make verify-nexmon' to check if monitor mode is working."

install-deps:
	@echo "--> Updating package lists and installing system dependencies..."
	sudo apt-get update
	sudo apt-get install -y $(DEPS)

setup-nexmon:
	@echo "--> Updating system, installing Nexmon DKMS drivers, and firmware..."
	sudo apt-get update
	sudo apt-get full-upgrade -y
	sudo apt-get install -y brcmfmac-nexmon-dkms firmware-nexmon
	@echo "✅ Nexmon driver package installation complete."
	@echo "   A reboot is REQUIRED for the new kernel module to be loaded."
	@echo "   You can run 'sudo reboot' now or after the full installation."

setup-pwnagotchi: install-deps
	@echo "--> Creating application directory at $(APP_DIR)..."
	sudo mkdir -p $(APP_DIR)
	@echo "--> Cloning Pwnagotchi repository from $(PWNAGOTCHI_REPO)..."
	sudo git clone --branch $(PWNAGOTCHI_BRANCH) $(PWNAGOTCHI_REPO) $(APP_DIR)
	@echo "--> Creating Python virtual environment at $(VENV_DIR)..."
	sudo $(PYTHON_EXECUTABLE) -m venv $(VENV_DIR)
	@echo "--> Installing Pwnagotchi Python dependencies..."
	sudo $(VENV_DIR)/bin/pip install --upgrade pip wheel
	sudo $(VENV_DIR)/bin/pip install -r $(APP_DIR)/requirements.txt
	@echo "--> Installing Pwnagotchi application..."
	sudo $(VENV_DIR)/bin/pip install --editable $(APP_DIR)
	@echo "--> Setting ownership for application directory..."
	sudo chown -R $(APP_USER):$(APP_USER) $(APP_DIR)

setup-config:
	@echo "--> Installing default configuration file to $(CONFIG_DIR)..."
	sudo mkdir -p $(CONFIG_DIR)
	@if [ -f "$(APP_DIR)/pwnagotchi/default-config.toml" ]; then \
		sudo cp $(APP_DIR)/pwnagotchi/default-config.toml $(CONFIG_DIR)/config.toml; \
		sudo chown -R root:root $(CONFIG_DIR); \
		sudo chmod 644 $(CONFIG_DIR)/config.toml; \
		echo "✅ Default config copied. Please edit '$(CONFIG_DIR)/config.toml' to customize."; \
	elif [ -f "$(CONFIG_FILE)" ]; then \
		sudo cp $(CONFIG_FILE) $(CONFIG_DIR)/; \
		sudo chown -R root:root $(CONFIG_DIR); \
		sudo chmod 644 $(CONFIG_DIR)/$(CONFIG_FILE); \
		echo "✅ Local config copied. Please edit '$(CONFIG_DIR)/$(CONFIG_FILE)' to customize."; \
	else \
		echo "⚠️ Warning: No default configuration file found. Please create one at '$(CONFIG_DIR)/config.toml'."; \
	fi

setup-service:
	@echo "--> Creating and enabling systemd service for Pwnagotchi..."
	@echo "[Unit]" | sudo tee /etc/systemd/system/$(PROJECT_NAME).service
	@echo "Description=Pwnagotchi service" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service
	@echo "After=network.target" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service
	@echo "" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service
	@echo "[Service]" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service
	@echo "Type=simple" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service
	@echo "User=root" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service
	@echo "Group=root" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service
	@echo "ExecStart=$(VENV_DIR)/bin/pwnagotchi --config $(CONFIG_DIR)/config.toml" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service
	@echo "Restart=always" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service
	@echo "RestartSec=30" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service
	@echo "" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service
	@echo "[Install]" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service
	@echo "WantedBy=multi-user.target" | sudo tee -a /etc/systemd/system/$(PROJECT_NAME).service
	sudo systemctl daemon-reload
	sudo systemctl enable $(PROJECT_NAME).service
	@echo "✅ Service '$(PROJECT_NAME).service' created and enabled."

##@ Uninstallation

uninstall: uninstall-service uninstall-pwnagotchi ## Uninstall Pwnagotchi and remove all related files.
	@echo "\n✅ Pwnagotchi uninstallation complete."

uninstall-service:
	@echo "--> Stopping and removing systemd service..."
	-sudo systemctl stop $(PROJECT_NAME).service
	-sudo systemctl disable $(PROJECT_NAME).service
	-sudo rm -f /etc/systemd/system/$(PROJECT_NAME).service
	-sudo systemctl daemon-reload

uninstall-pwnagotchi:
	@echo "--> Removing application files and directories..."
	-sudo rm -rf $(APP_DIR)
	-sudo rm -rf $(CONFIG_DIR)
	@echo "--> Uninstalling system dependencies (optional)..."
	@echo "   You can manually run 'sudo apt-get purge --auto-remove $(DEPS)' to remove dependencies."

##@ Service Management & Verification

start: ## Start the pwnagotchi systemd service.
	sudo systemctl start $(PROJECT_NAME).service

stop: ## Stop the pwnagotchi systemd service.
	sudo systemctl stop $(PROJECT_NAME).service

restart: ## Restart the pwnagotchi systemd service.
	sudo systemctl restart $(PROJECT_NAME).service

status: ## Check the status of the pwnagotchi systemd service.
	sudo systemctl status $(PROJECT_NAME).service

logs: ## Tail the logs for the pwnagotchi service.
	sudo journalctl -u $(PROJECT_NAME).service -f

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
		echo "   Run 'sudo airmon-ng start wlan0' manually if needed."; \
	fi

##@ Help

help: ## Show this help message.
	@echo "Usage: make [target]"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'