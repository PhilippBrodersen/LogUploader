#!/bin/bash

SEARCH_PATH="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_APP="$SCRIPT_DIR/GuildWars2EliteInsights-CLI"
CONFIG_FILE="$SCRIPT_DIR/sample.conf"
PROCESSED_FILE="$SCRIPT_DIR/.processed_hashes"
BATCH_SIZE=50
DB_FILE="$SCRIPT_DIR/hash_list.db"

sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS parsed (hash TEXT PRIMARY KEY);"

hash_file() {
    local file="$1"
    sha256sum "$file" | cut -d' ' -f1
}

parsed_before() {
    local h="$1"
    result=$(sqlite3 "$DB_FILE" "SELECT 1 FROM parsed WHERE hash='$h' LIMIT 1;")
    [[ "$result" == "1" ]]
}

set_parsed() {
    local h="$1"
    sqlite3 "$DB_FILE" "INSERT OR IGNORE INTO parsed(hash) VALUES('$h');"
}

count_parsed() {
    sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM parsed;"
}


all_files=()
while IFS= read -r f; do
    all_files+=("$f")
done < <(find "$SEARCH_PATH" -type f \( -name "*.evtc" -o -name "*.zevtc" \))

total_files=${#all_files[@]}
previously_done=$(count_parsed)
total_batches=$(( (total_files + BATCH_SIZE - 1) / BATCH_SIZE ))
current_batch_index=0

echo "Starting Elite Insight and looking for logs, this might take a tiny bit"
echo "Total files found: $total_files"
echo "Previously processed: $previously_done"

start_time=$(date +%s)
processed_times=()
window=5

update_progress() {
    local status="$1"
    local now=$(date +%s)

    processed_times+=("$now")
    while [[ ${#processed_times[@]} -gt 0 && ${processed_times[0]} -lt $((now - window)) ]]; do
        processed_times=("${processed_times[@]:1}")
    done
    local rate=$(echo "scale=2; ${#processed_times[@]} / $window" | bc)

    printf "\r\033[K[%s] Batch %d/%d: (%d / %d) [%.2f logs/sec]" \
        "$status" "$current_batch_index" "$total_batches" \
        "$current_batch" "$batch_max" "$rate"
}

process_batch() {
    local files=("$@")
    ((current_batch_index++))
    batch_max=${#files[@]}
    current_batch=0
    local batch_status="Preparing new batch"
	update_progress "$batch_status"

    while IFS= read -r line; do
        [[ $line == GuildWars2EliteInsights* || $line == Getting* ]] && continue

        if [[ $line == Parsing\ Successful* && $batch_status != "Running" ]]; then
            batch_status="Running"
        fi

        if [[ $line == Parsing* ]]; then
			((current_batch++))
            update_progress "$batch_status"
        else
            [[ -n "$line" ]] && echo "$line"
        fi
    done < <(stdbuf -oL "$CLI_APP" -c "$CONFIG_FILE" "${files[@]}")
    
    echo
}


batch=()
count=0
for file in "${all_files[@]}"; do
    hash=$(hash_file "$file")
	if parsed_before $hash; then
		continue
	fi

    batch+=("$file")
    ((++count))

    if ((count == BATCH_SIZE)); then
        process_batch "${batch[@]}"

		for f in "${batch[@]}"; do
            h=$(hash_file "$f")
            set_parsed "$h"
        done

        batch=()
        count=0
    fi
done

((count > 0)) && process_batch "${batch[@]}"

echo -e "\nAll done!"
