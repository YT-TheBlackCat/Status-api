#!/bin/bash
set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SERVICE_NAME=status-api
EXCLUDE="servers.json version.txt"
UPDATED=0
CHANGED_FILES=()

# --- Requirements auto-install (no requirements.txt needed) ---
function ensure_python_requirements() {
    echo -e "${BLUE}[status-api] Ensuring Python requirements...${NC}"
    source venv/bin/activate
    pip install --upgrade pip > /dev/null 2>&1
    pip install fastapi httpx uvicorn status requests tiktoken > /dev/null 2>&1
}

# Detect install or update mode
if [ ! -f "venv/bin/activate" ] || [ ! -f "servers.json" ]; then
    MODE="install"
else
    MODE="update"
fi

echo -e "${BLUE}[status-api] Detected mode: $MODE${NC}"

if [ "$MODE" = "install" ]; then
    # --- Install Section ---
    # Check for backup in ~/status-api-backup
    BACKUP_DIR="$HOME/status-api-backup"
    if [ ! -f "servers.json" ] && [ -f "$BACKUP_DIR/servers.json" ]; then
        echo -e "${YELLOW}[status-api] Found servers.json backup in $BACKUP_DIR. Restoring...${NC}"
        cp "$BACKUP_DIR/servers.json" servers.json
    fi
    if [ ! -f "servers.db" ] && [ -f "$BACKUP_DIR/servers.db" ]; then
        echo -e "${YELLOW}[status-api] Found servers.db backup in $BACKUP_DIR. Restoring...${NC}"
        cp "$BACKUP_DIR/servers.db" servers.db
    fi

    # Check for global servers.json in /home/$USER/servers.json
    GLOBAL_servers="/home/$USER/servers.json"
    if [ ! -f "servers.json" ] && [ -f "$GLOBAL_servers" ]; then
        echo -e "${GREEN}[status-api] Found global servers.json at $GLOBAL_servers. Using it.${NC}"
        cp "$GLOBAL_servers" servers.json
    fi

    # Only prompt for API keys if servers.json still does not exist
    if [ ! -f "servers.json" ]; then
        # Ask for multiple API keys
        servers=()
        echo -e "${YELLOW}Enter your status API keys (one per line). Leave empty and press Enter to finish:${NC}"
        while true; do
            read -p "API Key: " key
            if [[ -z "$key" ]]; then
                break
            fi
            servers+=("$key")
        done

        if [[ ${#servers[@]} -eq 0 ]]; then
            echo -e "${RED}No API keys entered. Exiting.${NC}"
            exit 1
        fi

        # Ask for custom local API key for test.sh
        while true; do
            read -p "Enter a custom local API key for test.sh (used as Authorization header, cannot be empty): " CUSTOM_API_KEY
            if [[ -n "$CUSTOM_API_KEY" ]]; then
                break
            else
                echo -e "${RED}Custom local API key cannot be empty. Please enter a value.${NC}"
            fi
        done

        # Create servers.json with custom local API key
        cat > servers.json <<EOF
{
  "custom_local_api_key": "$CUSTOM_API_KEY",
  "status_keys": [
$(for i in "${!servers[@]}"; do
    printf '    {"key": "%s"}%s\n' "${servers[$i]}" $( [[ $i -lt $((${#servers[@]}-1)) ]] && echo "," )
done)
  ]
}
EOF
        echo -e "${GREEN}[status-api] servers.json created with custom local API key.${NC}"
    fi

    # Create venv if not exists
    if [ ! -d "venv" ]; then
        echo -e "${BLUE}[status-api] Creating virtual environment...${NC}"
        python3 -m venv venv
    fi

    # Activate venv and install requirements (no requirements.txt needed)
    ensure_python_requirements

    # Ensure servers.db exists by initializing it if missing
    if [ ! -f "servers.db" ]; then
        echo -e "${BLUE}[status-api] Initializing servers.db...${NC}"
        python3 -c "import apikeymanager; apikeymanager.init_db()"
    fi

    # Ensure apikey_usage is pre-populated with all models/keys/limits
    echo -e "${BLUE}[status-api] Pre-populating servers.db with all models and API keys...${NC}"
    python3 -c "import apikeymanager; apikeymanager.init_db_with_limits()"

    # --- Install as systemd service (always) ---
    echo -e "${BLUE}[status-api] Installing as systemd service...${NC}"
    cat <<EOF | sudo tee /etc/systemd/system/status-api.service > /dev/null
[Unit]
Description=status API FastAPI Proxy
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000 --reload
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable status-api
    sudo systemctl restart status-api

    echo -e "${GREEN}[status-api] Service installed and started. Check status with: sudo systemctl status status-api${NC}"
    echo -e "${GREEN}[status-api] Installation complete.${NC}"
else
    # --- Update Section ---
    REMOTE_URL=$(git config --get remote.origin.url)
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

    if git ls-remote --exit-code origin HEAD &>/dev/null; then
        git fetch origin $BRANCH
    else
        echo -e "${RED}[status-api] No remote git repository found. Cannot update.${NC}"
        exit 1
    fi

    REMOTE_FILES=$(git ls-tree -r --name-only origin/$BRANCH)
    for file in $REMOTE_FILES; do
        skip=0
        for ex in $EXCLUDE; do
            if [[ "$file" == "$ex" ]]; then
                skip=1
                break
            fi
        done
        if [[ $skip -eq 1 ]]; then
            continue
        fi
        TMPFILE=$(mktemp)
        git show origin/$BRANCH:$file > "$TMPFILE" 2>/dev/null || continue
        if [[ ! -f "$file" ]]; then
            echo -e "${YELLOW}[status-api] Adding new file $file...${NC}"
            cp "$TMPFILE" "$file"
            UPDATED=1
            CHANGED_FILES+=("$file (new)")
        elif ! cmp -s "$file" "$TMPFILE"; then
            echo -e "${YELLOW}[status-api] Updating $file...${NC}"
            git checkout origin/$BRANCH -- "$file"
            UPDATED=1
            CHANGED_FILES+=("$file")
        fi
        rm -f "$TMPFILE"
    done

    VERSION=$(git rev-parse origin/$BRANCH)
    echo "$VERSION" > version.txt

    if [[ $UPDATED -eq 1 ]]; then
        echo -e "${GREEN}[status-api] Update complete. The following files were updated:${NC}"
        for f in "${CHANGED_FILES[@]}"; do
            echo -e "  ${GREEN}$f${NC}"
        done
    else
        echo -e "${YELLOW}[status-api] All files are already up to date. No changes made.${NC}"
    fi

    # Reinstall requirements on update
    ensure_python_requirements

    # Restart service after update
    sudo systemctl restart status-api
    echo -e "${GREEN}[status-api] Service restarted. Check status with: sudo systemctl status status-api${NC}"
    echo -e "${GREEN}[status-api] Update complete.${NC}"
fi

# Add alias for 'options' (not 'option') if not already present in ~/.bashrc
if ! grep -q 'alias options=' ~/.bashrc; then
    echo "alias options=\"bash $(realpath $0)\"" >> ~/.bashrc
    # Automatically reload bashrc so alias is available immediately
    if [ -n "$BASH_VERSION" ]; then
        source ~/.bashrc
        echo -e "${GREEN}[status-api] ~/.bashrc reloaded. 'options' alias is now available in this shell.${NC}"
    fi
fi
