#!/usr/bin/env bash

# Configuration
DATA_DIR="$HOME/.fintui"
DATA_FILE="$DATA_DIR/data.json"
REMOTE_REPO_URL="" # Add your Git remote URL here

# Ensure dependencies are installed
for cmd in fzf jq git; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is not installed."
        exit 1
    fi
done

# Initialize directory, data file, and Git repo
init_app() {
    if [ ! -d "$DATA_DIR" ]; then
        mkdir -p "$DATA_DIR"
        cd "$DATA_DIR" || exit
        git init
        
        # Initialize JSON skeleton
        echo '{"accounts": []}' > "$DATA_FILE"
        
        if [ -n "$REMOTE_REPO_URL" ]; then
            git remote add origin "$REMOTE_REPO_URL"
        fi
        
        git add data.json
        git commit -m "Initial commit"
    fi
}

# Helper to capture multiline input using terminal editor
get_multiline_input() {
    local temp_file=$(mktemp)
    # Pre-fill with existing data if provided
    [[ -n "$1" ]] && echo "$1" > "$temp_file"
    
    # Open editor attached to tty to prevent fzf freezing
    ${EDITOR:-nano} "$temp_file" < /dev/tty > /dev/tty
    
    cat "$temp_file"
    rm -f "$temp_file"
}

# View pending money and personal info
view_pending() {
    clear
    echo "--- Pending Money ---"
    
    # Extract pending accounts and format for fzf
    local selected
    selected=$(jq -r '.accounts[] | select(.status=="pending") | "\(.name) | ₹\(.amount) | Due: \(.due_date) | Info: \(.info | gsub("\n"; " ")) | ID: \(.id)"' "$DATA_FILE" | \
        fzf --prompt="Search records > " --layout=reverse --header="Select a record to mark as PAID or ESC to cancel")

    if [ -n "$selected" ]; then
        # Extract ID from the selected string
        local record_id=$(echo "$selected" | awk -F'ID: ' '{print $2}')
        
        read -p "Mark this record (ID: $record_id) as paid? (y/n): " confirm
        if [[ "$confirm" == "y" ]]; then
            jq --arg id "$record_id" '(.accounts[] | select(.id == $id) | .status) = "paid"' "$DATA_FILE" > "$DATA_FILE.tmp" && mv "$DATA_FILE.tmp" "$DATA_FILE"
            echo "Record marked as paid."
            sleep 1
        fi
    fi
}

# Add a new record
add_record() {
    clear
    echo "--- Add New Pending Money ---"
    read -p "Name: " name
    read -p "Amount (₹): " amount
    read -p "Due Date (YYYY-MM-DD): " due_date
   
    echo "Opening editor for Personal Info (Save and Exit when done)..."
    sleep 1
    local info=$(get_multiline_input) 
    local id=$(date +%s) # Unique ID based on timestamp
    
    jq --arg id "$id" --arg name "$name" --arg amount "$amount" --arg date "$due_date" --arg info "$info" \
    '.accounts += [{"id": $id, "name": $name, "amount": $amount, "due_date": $date, "info": $info, "status": "pending"}]' \
    "$DATA_FILE" > "$DATA_FILE.tmp" && mv "$DATA_FILE.tmp" "$DATA_FILE"
    
    echo "Record added successfully."
    sleep 1
}

# Edit an existing record
edit_record() {
    clear
    echo "--- Edit Record ---"
    local selected=$(jq -r '.accounts[] | "\(.name) | ₹\(.amount) | Due: \(.due_date) | ID: \(.id)"' "$DATA_FILE" | \
        fzf --prompt="Select record to edit > " --layout=reverse)
    
    [[ -z "$selected" ]] && return
    
    local record_id=$(echo "$selected" | awk -F'ID: ' '{print $2}')
    
    # Fetch current values
    local current_name=$(jq -r --arg id "$record_id" '.accounts[] | select(.id == $id) | .name' "$DATA_FILE")
    local current_amount=$(jq -r --arg id "$record_id" '.accounts[] | select(.id == $id) | .amount' "$DATA_FILE")
    local current_due=$(jq -r --arg id "$record_id" '.accounts[] | select(.id == $id) | .due_date' "$DATA_FILE")
    local current_info=$(jq -r --arg id "$record_id" '.accounts[] | select(.id == $id) | .info' "$DATA_FILE")
    
    local field_choice=$(printf "1. Name\n2. Amount\n3. Due Date\n4. Info\n5. Cancel" | fzf --prompt="Select field to edit > " --layout=reverse --height=40%)
    
    local field=""
    local new_val=""
    local old_val=""
    
    case "$field_choice" in
        1*) 
            read -p "New Name [$current_name]: " new_val
            [[ -z "$new_val" ]] && new_val="$current_name"
            field="name"; old_val="$current_name" ;;
        2*) 
            read -p "New Amount [$current_amount]: ₹" new_val
            [[ -z "$new_val" ]] && new_val="$current_amount"
            field="amount"; old_val="$current_amount" ;;
        3*) 
            read -p "New Due Date [$current_due]: " new_val
            [[ -z "$new_val" ]] && new_val="$current_due"
            field="due_date"; old_val="$current_due" ;;
        4*) 
            echo "Opening editor for Info (Save and Exit when done)..."
            sleep 1
            new_val=$(get_multiline_input "$current_info")
            field="info"; old_val="$current_info" ;;
        *) return ;;
    esac
    
    # Confirmation prompt
    clear
    echo "--- Confirm Changes ---"
    echo "Field: $field"
    echo "Old Value:"
    echo "$old_val"
    echo "-----------------------"
    echo "New Value:"
    echo "$new_val"
    echo "-----------------------"
    
    read -p "Save this change? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        jq --arg id "$record_id" --arg val "$new_val" --arg field "$field" \
        '(.accounts[] | select(.id == $id))[$field] = $val' "$DATA_FILE" > "$DATA_FILE.tmp" && mv "$DATA_FILE.tmp" "$DATA_FILE"
        echo "Record updated successfully."
    else
        echo "Edit cancelled."
    fi
    sleep 1.5
}

# Check reminders (Overdue or due in next 7 days)
check_reminders() {
    clear
    echo "--- Reminders ---"
    local today=$(date +%s)
    local seven_days=$((today + 604800))
    
    jq -c '.accounts[] | select(.status=="pending")' "$DATA_FILE" | while read -r row; do
        local due_date=$(echo "$row" | jq -r '.due_date')
        local name=$(echo "$row" | jq -r '.name')
        local amount=$(echo "$row" | jq -r '.amount')
        
        # Convert due_date to epoch for comparison
        local due_epoch=$(date -d "$due_date" +%s 2>/dev/null)
        
        if [[ -n "$due_epoch" ]]; then
            if [[ $due_epoch -lt $today ]]; then
                echo "🚨 OVERDUE: $name owes ₹$amount (Due: $due_date)"
            elif [[ $due_epoch -le $seven_days ]]; then
                echo "⚠️ UPCOMING: $name owes ₹$amount (Due: $due_date)"
            fi
        fi
    done
    echo ""
    read -p "Press Enter to return to menu..."
}

# Sync with Git Remote
sync_git() {
    clear
    echo "--- Syncing with Remote ---"
    cd "$DATA_DIR" || exit
    
    if git pull origin main 2>/dev/null; then
        echo "Pulled latest changes."
    else
        echo "No remote found or pull failed."
    fi
    
    git add data.json
    git commit -m "Auto-sync: $(date '+%Y-%m-%d %H:%M:%S')"
    git push origin main
    
    echo "Sync complete."
    read -p "Press Enter to continue..."
}

# Main Loop
init_app

while true; do
    clear
    choice=$(printf "1. View Pending Money\n2. Add New Record\n3. Edit Record\n4. Check Reminders\n5. Sync with Git\n6. Exit" | \
        fzf --prompt="Main Menu > " --layout=reverse --height=40%)
    
    case "$choice" in
        1*) view_pending ;;
        2*) add_record ;;
        3*) edit_record ;;
        4*) check_reminders ;;
        5*) sync_git ;;
        6*) exit 0 ;;
    esac
done
