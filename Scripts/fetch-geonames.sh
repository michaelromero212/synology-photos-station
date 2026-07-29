#!/bin/bash
# Builds the offline reverse-geocoding dataset.
#
#   ./Scripts/fetch-geonames.sh [output-dir]     # default: ./Data/geonames
#
# Downloads GeoNames cities1000 (every settlement over 1,000 people) and the
# admin1 code table, then trims both to only the fields the geocoder reads. The
# raw dump is ~30 MB of text with 19 columns; the trimmed form is ~5 MB with 5.
#
# Why offline at all: the alternative is calling a geocoding API with the
# family's location history, one request per photo, 100,000 times. This keeps
# every coordinate on the NAS and costs nothing per lookup.
#
# CC-BY 4.0, https://www.geonames.org/ — attribution required if redistributed.
set -euo pipefail

OUT="${1:-$(cd "$(dirname "$0")/.." && pwd)/Data/geonames}"
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading GeoNames…"
curl -fsSL -o "$TMP/cities1000.zip" https://download.geonames.org/export/dump/cities1000.zip
curl -fsSL -o "$TMP/admin1.txt"     https://download.geonames.org/export/dump/admin1CodesASCII.txt
unzip -qo "$TMP/cities1000.zip" -d "$TMP"

# cities1000.txt columns (1-indexed for awk):
#   3 asciiname   5 latitude   6 longitude   9 country code   11 admin1 code
echo "Trimming…"
awk -F'\t' 'NF>=11 && $5 != "" && $6 != "" {
    printf "%s\t%s\t%s\t%s\t%s\n", $3, $5, $6, $9, $11
}' "$TMP/cities1000.txt" > "$OUT/cities.tsv"

# admin1CodesASCII.txt: "US.VA<TAB>Virginia<TAB>Virginia<TAB>6254928"
awk -F'\t' 'NF>=2 { printf "%s\t%s\n", $1, $2 }' "$TMP/admin1.txt" > "$OUT/admin1.tsv"

printf 'GeoNames (https://www.geonames.org/) — CC BY 4.0\n' > "$OUT/ATTRIBUTION.txt"

echo
echo "  $OUT/cities.tsv   $(wc -l < "$OUT/cities.tsv" | tr -d ' ') places, $(du -h "$OUT/cities.tsv" | cut -f1)"
echo "  $OUT/admin1.tsv   $(wc -l < "$OUT/admin1.tsv" | tr -d ' ') regions"
echo
echo "Point the server at it with FRAMESTATION_GEONAMES_DIR=$OUT"
