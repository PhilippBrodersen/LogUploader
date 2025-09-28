#!/bin/bash

SEARCH_PATH="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_APP="$SCRIPT_DIR/GuildWars2EliteInsights-CLI"
CONFIG_FILE="$SCRIPT_DIR/sample.conf"
PROCESSED_FILE="$SCRIPT_DIR/.processed_hashes"
BATCH_SIZE=500  # adjust to balance CLI startup overhead vs RAM

touch "$PROCESSED_FILE"

# Load processed hashes
declare -A processed
if [[ -s "$PROCESSED_FILE" ]]; then
    mapfile -t hashes < "$PROCESSED_FILE"
    for h in "${hashes[@]}"; do
        processed["$h"]=1
    done
fi

hash_path() { echo -n "$1" | sha256sum | cut -d' ' -f1; }

all_files=()
while IFS= read -r f; do
    all_files+=("$f")
done < <(find "$SEARCH_PATH" -type f \( -name "*.evtc" -o -name "*.zevtc" \))

total_files=${#all_files[@]}
previously_done=${#processed[@]}
total_batches=$(( (total_files + BATCH_SIZE - 1) / BATCH_SIZE ))
current_batch_index=0

echo "Starting Elite Insight and looking for logs, this might take a tiny bit"
echo "Total files found: $total_files"
echo "Previously processed: $previously_done"

done_count=${#processed[@]}
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

    printf "\r[%s] Batch %d/%d: (%d / %d) [%.2f logs/sec]" \
        "$status" "$current_batch_index" "$total_batches" \
        "$current_batch" "$batch_max" "$rate"
}

process_batch() {
    local files=("$@")
	((current_batch_index++))
    batch_max=${#files[@]}
    current_batch=0
	local batch_status="Preparing new batch"

    "$CLI_APP" -c "$CONFIG_FILE" "${files[@]}" | while IFS= read -r line; do

		[[ $line == GuildWars2EliteInsights* || $line == Getting* ]] && continue

        if [[ $line == Parsing\ Successful* && $batch_status != "Running" ]]; then
            batch_status="Running"
        fi

        if [[ $line == Parsing\ Successful* ]]; then
            file="${line#Parsing Successful - }"
            h=$(hash_path "$file")
            if [[ -z ${processed[$h]} ]]; then
                echo "$h" >> "$PROCESSED_FILE"
                processed["$h"]=1
            fi
            ((done_count++))
            ((current_batch++))
            update_progress "$batch_status"
        elif [[ $line == Parsing* ]]; then
            continue
        else
            [[ -n "$line" ]] && echo "$line"
        fi
    done
    echo
}

batch=()
count=0
for file in "${all_files[@]}"; do
    h=$(hash_path "$file")
    [[ -n ${processed[$h]} ]] && continue

    batch+=("$file")
    ((++count))

    if ((count == BATCH_SIZE)); then
        process_batch "${batch[@]}"
        batch=()
        count=0
    fi
done

((count > 0)) && process_batch "${batch[@]}"

echo -e "\nAll done!"
