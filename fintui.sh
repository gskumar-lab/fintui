#!/usr/bin/env bash

# Configuration
DATA_DIR="$HOME/.fintui"
DATA_FILE="$DATA_DIR/data.json"
REMOTE_REPO_URL="" # Add your Git remote URL here

# Ensure dependencies are installed
for cmd in fzf jq git notify-send; do
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

# --- UI & Styling ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Set a unified fzf theme with borders and distinct colors
export FZF_DEFAULT_OPTS="
  --layout=reverse
  --border=rounded
  --color=bg+:#282c34,bg:#1e2127,spinner:#e06c75,hl:#e5c07b
  --color=fg:#abb2bf,header:#61afef,info:#c678dd,pointer:#c678dd
  --color=marker:#98c379,fg+:#ffffff,prompt:#61afef,hl+:#e5c07b
"

# Helper for colored headers
print_header() {
    echo -e "${CYAN}${BOLD}=== $1 ===${NC}\n"
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

# View pending money and log payments
view_pending() {
    clear
    print_header "Pending Money"
    
    local selected
    selected=$(jq -r '.accounts[] | select(.status=="pending") | 
        "\(.name) | Remaining: ₹\((.amount|tonumber) - (.amount_paid // 0 | tonumber)) | Due: \(.due_date) | ID: \(.id)"' "$DATA_FILE" | \
        column -t -s '|' | \
        fzf --prompt="Search records > " \
            --header="Select a record to log a payment or ESC to cancel" \
            --preview="id=\$(echo {} | awk -F'ID: ' '{print \$2}' | tr -d ' '); jq -r --arg i \"\$id\" '.accounts[] | select(.id == \$i) | \"Name: \(.name)\nTotal: ₹\(.amount)\nPaid:  ₹\(.amount_paid // 0)\nDue:   \(.due_date)\n\nNotes:\n\(.info)\"' \"$DATA_FILE\"" \
            --preview-window=right:40%:wrap)

    if [ -n "$selected" ]; then
        local record_id=$(echo "$selected" | awk -F'ID: ' '{print $2}' | tr -d ' ')
        
        local current_amount=$(jq -r --arg id "$record_id" '.accounts[] | select(.id == $id) | .amount' "$DATA_FILE")
        local current_paid=$(jq -r --arg id "$record_id" '.accounts[] | select(.id == $id) | (.amount_paid // 0)' "$DATA_FILE")
        local remaining=$((current_amount - current_paid))
        
        echo -e "${YELLOW}Remaining balance: ₹$remaining${NC}"
        read -p "Enter payment amount (Leave blank for full ₹$remaining): ₹" payment_input
        
        local payment=0
        if [[ -z "$payment_input" ]]; then
            payment=$remaining
        else
            payment=$payment_input
        fi
        
        local new_paid=$((current_paid + payment))
        
        if [[ $new_paid -ge $current_amount ]]; then
            jq --arg id "$record_id" --argjson paid "$new_paid" '(.accounts[] | select(.id == $id)) |= (.amount_paid = $paid | .status = "paid")' "$DATA_FILE" > "$DATA_FILE.tmp" && mv "$DATA_FILE.tmp" "$DATA_FILE"
            echo -e "${GREEN}Payment logged. Record fully paid!${NC}"
        else
            jq --arg id "$record_id" --argjson paid "$new_paid" '(.accounts[] | select(.id == $id)) |= (.amount_paid = $paid)' "$DATA_FILE" > "$DATA_FILE.tmp" && mv "$DATA_FILE.tmp" "$DATA_FILE"
            echo -e "${GREEN}Partial payment of ₹$payment logged. Remaining: ₹$((current_amount - new_paid)).${NC}"
        fi
        
        auto_sync_background
        sleep 1.5
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
    
    local id=$(date +%s)
    
    # Added "amount_paid": 0
    jq --arg id "$id" --arg name "$name" --arg amount "$amount" --arg date "$due_date" --arg info "$info" \
    '.accounts += [{"id": $id, "name": $name, "amount": $amount, "amount_paid": 0, "due_date": $date, "info": $info, "status": "pending"}]' \
    "$DATA_FILE" > "$DATA_FILE.tmp" && mv "$DATA_FILE.tmp" "$DATA_FILE"
    
    echo "Record added successfully."
    auto_sync_background
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
	auto_sync_background
    else
        echo "Edit cancelled."
    fi
    sleep 1.5
}

# Check reminders (Overdue or due in next 7 days)
check_reminders() {
    clear
    print_header "Reminders"
    local today=$(date +%s)
    local seven_days=$((today + 604800))
    
    jq -c '.accounts[] | select(.status=="pending")' "$DATA_FILE" | while read -r row; do
        local due_date=$(echo "$row" | jq -r '.due_date')
        local name=$(echo "$row" | jq -r '.name')
        local amount=$(echo "$row" | jq -r '.amount')
        local paid=$(echo "$row" | jq -r '(.amount_paid // 0)')
        local remaining=$((amount - paid))
        
        local due_epoch=$(date -d "$due_date" +%s 2>/dev/null)
        
        if [[ -n "$due_epoch" ]]; then
            if [[ $due_epoch -lt $today ]]; then
                echo -e "${RED}🚨 OVERDUE: $name owes ₹$remaining (Due: $due_date)${NC}"
            elif [[ $due_epoch -le $seven_days ]]; then
                echo -e "${YELLOW}⚠️ UPCOMING: $name owes ₹$remaining (Due: $due_date)${NC}"
            fi
        fi
    done
    echo ""
    read -p "Press Enter to return to menu..."
}

# Interactive Git Sync with Edge Case Handling
sync_git() {
    clear
    echo "--- Interactive Git Sync ---"
    cd "$DATA_DIR" || exit
    
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)

    # Edge Case 1: No remote configured dynamically
    if ! git remote | grep -q '^origin$'; then
        echo "No remote repository configured."
        read -p "Enter remote Git URL (or press Enter to abort): " new_remote
        if [[ -z "$new_remote" ]]; then
            return
        fi
        git remote add origin "$new_remote"
    fi

    # Edge Case 2: Commit local changes BEFORE pulling to avoid overwrites
    if ! git diff --quiet data.json || ! git diff --cached --quiet data.json; then
        echo "Local changes detected."
        git add data.json
        read -p "Enter commit message [Auto-sync]: " msg
        [[ -z "$msg" ]] && msg="Auto-sync: $(date '+%Y-%m-%d %H:%M:%S')"
        git commit -m "$msg"
    else
        echo "No local changes to commit."
    fi

    # Edge Case 3: Pulling with Interactive Merge Conflict Handling
    echo "Pulling from remote..."
    # --no-edit prevents vim opening automatically for standard merge commits
    if ! git pull origin "$branch" --no-edit 2>/dev/null; then
        # Check if it actually failed due to a conflict
        if git ls-files -u | grep -q 'data.json'; then
            echo "⚠️ MERGE CONFLICT DETECTED in data.json!"
            local resolve_choice
            resolve_choice=$(printf "1. Keep Local Data\n2. Keep Remote Data\n3. Abort Sync (Fix manually)" | \
                fzf --prompt="Resolve Conflict > " --layout=reverse --height=30%)
            
            case "$resolve_choice" in
                1*)
                    git checkout --ours data.json
                    git add data.json
                    git commit -m "Conflict resolved: kept local data"
                    ;;
                2*)
                    git checkout --theirs data.json
                    git add data.json
                    git commit -m "Conflict resolved: kept remote data"
                    ;;
                *)
                    git merge --abort
                    echo "Sync aborted. Data is safe but out of sync."
                    read -p "Press Enter to return to menu..."
                    return
                    ;;
            esac
        else
            echo "Pull failed (Remote might be empty or unreachable, proceeding to push)."
        fi
    fi

    # Edge Case 4: Pushing with upstream tracking for first-time pushes
    echo "Pushing to remote..."
    if git push -u origin "$branch"; then
        echo "✅ Sync complete!"
    else
        echo "❌ Push failed. Check your network or credentials."
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# Background Autosync with Notifications
auto_sync_background() {
    # Run inside a subshell to avoid changing the main script's working directory
    (
        cd "$DATA_DIR" || exit
        
        # Abort if no remote is configured yet
        if ! git remote | grep -q '^origin$'; then
            exit 0
        fi

        # Check if there are actually changes to sync
        if git diff --quiet data.json && git diff --cached --quiet data.json; then
            exit 0
        fi

        # Commit local changes silently
        git add data.json
        git commit -m "Autosync: $(date '+%Y-%m-%d %H:%M:%S')" > /dev/null 2>&1

        local branch
        branch=$(git rev-parse --abbrev-ref HEAD)

        # Attempt silent pull
        if git pull origin "$branch" --no-edit > /dev/null 2>&1; then
            # Attempt silent push
            if git push -u origin "$branch" > /dev/null 2>&1; then
                notify-send "FinTUI" "✅ Cloud sync complete" -t 3000
            else
                notify-send "FinTUI Error" "❌ Git push failed. Check network." -u critical
            fi
        else
            # If pull fails, it's likely a merge conflict.
            notify-send "FinTUI Alert" "⚠️ Merge conflict detected! Please run Manual Sync." -u critical
        fi
    ) & # The '&' ensures this block runs in the background
}

# View past (paid) transactions and allow reverting to pending
view_past() {
    clear
    echo "--- Past (Paid) Transactions ---"
    
    local selected
    selected=$(jq -r '.accounts[] | select(.status=="paid") | 
        "\(.name) | Total: ₹\(.amount) | Paid: ₹\(.amount_paid // .amount) | Due: \(.due_date) | ID: \(.id)"' "$DATA_FILE" | \
        fzf --prompt="Search past records > " --layout=reverse --header="Select a record to REVERT to pending or ESC to cancel")

    if [ -n "$selected" ]; then
        local record_id=$(echo "$selected" | awk -F'ID: ' '{print $2}')
        
        read -p "Revert this record (ID: $record_id) back to pending? (y/n): " confirm
        if [[ "$confirm" == "y" ]]; then
            jq --arg id "$record_id" '(.accounts[] | select(.id == $id) | .status) = "pending"' "$DATA_FILE" > "$DATA_FILE.tmp" && mv "$DATA_FILE.tmp" "$DATA_FILE"
            echo "Record reverted to pending."
            auto_sync_background
            sleep 1
        fi
    fi
}

# Delete any record (pending or paid) permanently
delete_record() {
    clear
    echo "--- Delete Record ---"
    
    # Shows both pending and paid records, prefixed with their status
    local selected
    selected=$(jq -r '.accounts[] | "[\(.status | ascii_upcase)] \(.name) | ₹\(.amount) | Due: \(.due_date) | ID: \(.id)"' "$DATA_FILE" | \
        fzf --prompt="Select record to DELETE > " --layout=reverse --header="WARNING: This action is permanent!")

    if [ -n "$selected" ]; then
        local record_id=$(echo "$selected" | awk -F'ID: ' '{print $2}')
        
        read -p "Are you sure you want to PERMANENTLY DELETE this record? (y/n): " confirm
        if [[ "$confirm" == "y" ]]; then
            # map(select()) is the safest way to remove an object from a JSON array without leaving nulls
            jq --arg id "$record_id" '.accounts |= map(select(.id != $id))' "$DATA_FILE" > "$DATA_FILE.tmp" && mv "$DATA_FILE.tmp" "$DATA_FILE"
            echo "Record deleted successfully."
            auto_sync_background
            sleep 1
        fi
    fi
}

# Summary Dashboard with Sorting
show_dashboard() {
    clear
    
    local total_pending=$(jq '[.accounts[] | select(.status=="pending") | (.amount|tonumber) - (.amount_paid // 0 | tonumber)] | add // 0' "$DATA_FILE")
    local count_pending=$(jq '[.accounts[] | select(.status=="pending")] | length' "$DATA_FILE")
    
    local sort_choice=$(printf "1. Sort by Due Date (Closest first)\n2. Sort by Remaining Amount (Highest first)\n3. Sort by Name (A-Z)\n4. Cancel" | \
        fzf --prompt="Sort Dashboard By > " --header="Dashboard: ₹${total_pending} pending from ${count_pending} records.")
        
    local jq_sort=""
    case "$sort_choice" in
        "1."*) jq_sort='sort_by(.due_date)' ;;
        "2."*) jq_sort='sort_by((.amount|tonumber) - (.amount_paid // 0 | tonumber)) | reverse' ;;
        "3."*) jq_sort='sort_by(.name)' ;;
        *) return ;;
    esac
    
    clear
    jq -r ".accounts | map(select(.status==\"pending\")) | $jq_sort | .[] | 
        \"\(.name) | Remaining: ₹\((.amount|tonumber) - (.amount_paid // 0 | tonumber)) | Due: \(.due_date) | ID: \(.id)\"" "$DATA_FILE" | \
        column -t -s '|' | \
        fzf --prompt="Press ESC to return > " \
            --header="💰 Total Pending: ₹${total_pending}" \
            --preview="id=\$(echo {} | awk -F'ID: ' '{print \$2}' | tr -d ' '); jq -r --arg i \"\$id\" '.accounts[] | select(.id == \$i) | \"Notes:\n\(.info)\"' \"$DATA_FILE\"" \
            --preview-window=down:30%:wrap \
            --bind "enter:abort"
}

# Send WhatsApp Reminder
send_whatsapp() {
    clear
    echo "--- Send WhatsApp Reminder ---"
    
    local selected
    selected=$(jq -r '.accounts[] | select(.status=="pending") | 
        "\(.name) | Remaining: ₹\((.amount|tonumber) - (.amount_paid // 0 | tonumber)) | Due: \(.due_date) | ID: \(.id)"' "$DATA_FILE" | \
        fzf --prompt="Select record > " --layout=reverse --header="Select a person to send a reminder")

    if [ -n "$selected" ]; then
        local record_id=$(echo "$selected" | awk -F'ID: ' '{print $2}')
        
        # Fetch current details including info
        local name=$(jq -r --arg id "$record_id" '.accounts[] | select(.id == $id) | .name' "$DATA_FILE")
        local total=$(jq -r --arg id "$record_id" '.accounts[] | select(.id == $id) | .amount' "$DATA_FILE")
        local paid=$(jq -r --arg id "$record_id" '.accounts[] | select(.id == $id) | (.amount_paid // 0)' "$DATA_FILE")
        local due_date=$(jq -r --arg id "$record_id" '.accounts[] | select(.id == $id) | .due_date' "$DATA_FILE")
        local info=$(jq -r --arg id "$record_id" '.accounts[] | select(.id == $id) | .info' "$DATA_FILE")
        local remaining=$((total - paid))
        
        clear
        echo "--- Info on file for $name ---"
        echo "$info"
        echo "-------------------------------"
        
        # Try to automatically extract a phone number from the info field (10-12 digits)
        local auto_phone=$(echo "$info" | grep -oE '\+?[0-9]{10,12}' | head -n 1 | tr -d '+')
        
        local phone=""
        if [[ -n "$auto_phone" ]]; then
            read -p "Enter WhatsApp number [$auto_phone]: " phone
            [[ -z "$phone" ]] && phone="$auto_phone"
        else
            read -p "Enter WhatsApp number (e.g., 919876543210): " phone
        fi
        
        if [[ -z "$phone" ]]; then
            echo "Number cannot be empty. Cancelled."
            sleep 1
            return
        fi
        
        # Clean up the number just in case
        phone=$(echo "$phone" | tr -d ' +' )
        
        # Draft the message
        local msg="Hi $name, this is a gentle reminder regarding the pending amount of ₹$remaining. (Total was ₹$total, due on $due_date). Please let me know when you can process this. Thanks!"
        
        # URL encode the message using jq
        local encoded_msg=$(jq -nr --arg v "$msg" '$v|@uri')
        local url="https://wa.me/${phone}?text=${encoded_msg}"
        
        echo "Opening WhatsApp..."
        if command -v xdg-open &> /dev/null; then
            xdg-open "$url" > /dev/null 2>&1
        elif command -v open &> /dev/null; then
            open "$url" > /dev/null 2>&1
        else
            echo "Could not launch browser automatically. Open this link:"
            echo "$url"
            read -p "Press Enter to return..."
        fi
    fi
}

# Export JSON data to CSV
export_csv() {
    clear
    echo "--- Export Data to CSV ---"
    
    # Default filename with timestamp in the user's home directory
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local default_file="$HOME/fintui_export_$timestamp.csv"
    
    read -p "Enter file path to save [$default_file]: " export_path
    [[ -z "$export_path" ]] && export_path="$default_file"
    
    # jq filter generates headers, then maps each account array into @csv format
    jq -r '
    ["ID", "Name", "Total Amount", "Amount Paid", "Remaining", "Due Date", "Status", "Info"],
    (.accounts[] | [
        .id, 
        .name, 
        .amount, 
        (.amount_paid // 0), 
        ((.amount|tonumber) - (.amount_paid // 0 | tonumber)), 
        .due_date, 
        .status, 
        .info
    ]) | @csv' "$DATA_FILE" > "$export_path"
    
    if [[ $? -eq 0 ]]; then
        echo "✅ Export successful! Saved to:"
        echo "$export_path"
    else
        echo "❌ Export failed. Check folder permissions."
    fi
    echo ""
    read -p "Press Enter to return to menu..."
}

# Main Loop
init_app

while true; do
    clear
    total_pending=$(jq '[.accounts[] | select(.status=="pending") | (.amount|tonumber) - (.amount_paid // 0 | tonumber)] | add // 0' "$DATA_FILE")
    count_pending=$(jq '[.accounts[] | select(.status=="pending")] | length' "$DATA_FILE")
    
    header_text="💰 OVERALL PENDING: ₹${total_pending} across ${count_pending} active records"
    
    choice=$(printf "1. Summary Dashboard (Sort & View)\n2. View Pending Money (Log Payments)\n3. View Past (Paid) Money\n4. Add New Record\n5. Edit Record\n6. Delete Record\n7. Check Reminders\n8. Send WhatsApp Reminder\n9. Manual Git Sync\n10. Export to CSV\n11. Exit" | \
        fzf --prompt="Main Menu > " --layout=reverse --height=70% --header="$header_text")
    
    case "$choice" in
        "1."*) show_dashboard ;;
        "2."*) view_pending ;;
        "3."*) view_past ;;
        "4."*) add_record ;;
        "5."*) edit_record ;;
        "6."*) delete_record ;;
        "7."*) check_reminders ;;
        "8."*) send_whatsapp ;;
        "9."*) sync_git ;;
        "10."*) export_csv ;;
        "11."*) exit 0 ;;
    esac
done


