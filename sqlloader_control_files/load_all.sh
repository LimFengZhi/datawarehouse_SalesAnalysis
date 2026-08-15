#!/bin/bash
# ===================================================================
# load_all.sh - SQL*Loader batch load (Linux/Mac), parent tables first
#
# Usage: ./load_all.sh username password connect_string [data_folder]
#
#   ./load_all.sh dwh mypass XE
#       -> uses the sibling "data" folder automatically
#
#   ./load_all.sh dwh mypass XE /path/to/csv_folder
#       -> uses the folder you name
#
# Run from ANY directory: the script finds its own .ctl files and then
# cd's into the CSV folder so the INFILE names inside each .ctl resolve.
# ===================================================================
set -u

U=${1:-}; P=${2:-}; DB=${3:-}

CTL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA=${4:-"$CTL/../data"}

if [ -z "$DB" ]; then
    echo "Usage: ./load_all.sh username password connect_string [data_folder]"
    echo "Example: ./load_all.sh dwh mypass XE"
    exit 1
fi

if [ ! -f "$DATA/branch.csv" ]; then
    echo "ERROR: branch.csv not found in $DATA"
    echo "Point the 4th argument at the folder holding the CSV files."
    exit 1
fi

echo "Control files : $CTL"
echo "CSV folder    : $DATA"
echo

cd "$DATA" || exit 1

for T in branch supplier product service branch_utils_category staff customer \
         branch_expense salary_payment orders order_detail reservation \
         reservation_detail purchase; do
    echo "Loading $T ..."
    sqlldr "$U/$P@$DB" control="$CTL/$T.ctl" log="$CTL/$T.log" rows=5000 \
        || echo "   *** $T reported errors - check $T.log"
done

echo
echo "Done. Logs are in $CTL"
echo "Check each .log for 'Rows successfully loaded'."
echo "Rejected rows (if any) land in .bad files in $DATA"
