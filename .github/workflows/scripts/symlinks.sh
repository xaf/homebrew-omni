#!/usr/bin/env bash

set -euo pipefail

# Check that jq is installed
if ! command -v jq &> /dev/null; then
	echo "jq is required but not installed. Please install jq to run this script."
	exit 1
fi

# Use getopt to get the versions file path
VERSIONS_FILE=${VERSIONS_FILE:-"Formula/resources/omni_releases.json"}

while getopts ":f:" opt; do
	case $opt in
		f)
			VERSIONS_FILE="$OPTARG"
			;;
		\?)
			echo "Invalid option: -$OPTARG" >&2
			exit 1
			;;
		:)
			echo "Option -$OPTARG requires an argument." >&2
			exit 1
			;;
		*)
			echo "Usage: $0 [-f versions_file]"
			exit 1
			;;
	esac
done

# Check if we have a version file
if [[ ! -f "$VERSIONS_FILE" ]]; then
	echo "Versions file not found: $VERSIONS_FILE"
	exit 1
fi

# Get all versions from the JSON file
versions=($(jq --raw-output '.[]["version"]' "$VERSIONS_FILE"))

# Go to the Formula directory
cd Formula/

# Remove symlinks for non-existing versions
for file in omni@*.rb; do
	version="${file#omni@}"
	version="${version%.rb}"

	if [[ ! " ${versions[@]} " =~ " ${version} " ]]; then
		echo "Removing symlink for non-existing version: $file"
		rm -f "$file"
	fi
done

# Ensure symlinks for all existing versions
for version in "${versions[@]}"; do
	version_file="omni@${version}.rb"
	if [[ ! -L "${version_file}" ]]; then
		echo "Creating symlink for ${version_file}"
		ln -s "omni.rb" "${version_file}"
	fi
done
