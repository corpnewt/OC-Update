#!/usr/bin/env bash

clear

ARCHS=X64
TARGETS=RELEASE
RTARGETS=RELEASE
export ARCHS
export TARGETS
export RTARGETS

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

oc_url="https://github.com/acidanthera/OpenCorePkg"
to_copy="TRUE"
to_reveal="FALSE"
target_disk="$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path | sed 's/.*GPT,\([^,]*\),.*/\1/')"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -nocopy) to_copy="FALSE" ;;
        -reveal) to_reveal="TRUE" ;;
        -debug) TARGETS=DEBUG; RTARGETS=DEBUG ;;
        -disk) target_disk=$2; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

export ARCHS
export TARGETS
export RTARGETS

function clone_and_build () {
    local name="$1"
    local url="$2"
    local temp="$3"
    cd "$temp"
    echo "Cloning $url..."
    git clone "$url" && cd "$name"
    echo " - Building..."
    # First we symlink the UDK dir if it exists in the temp folder
    if [ -d "$temp/UDK" ]; then
        echo " - Linking UDK..."
        ln -s "$temp/UDK" "$temp/$name/UDK"
        echo " - Linking $name..."
        ln -s "$temp/$name" "$temp/UDK/$name"
    fi
    if [ -e "build_oc.tool" ]; then
        echo " - Running build_oc.tool"
        ./build_oc.tool
    elif [ -e "macbuild.tool" ]; then
        echo " - Running macbuild.tool"
        ./macbuild.tool
    else
        echo " - No known build tool found - skipping."
    fi
}

function find_and_copy () {
    local source="$1"
    local dest="$2"
    local name="$3"
    local include="$4"
    local exclude="$5"
    local dir="$PWD"
    cd "$source"
    find . -name "$name" | while read f; do
        # Make sure that we have a match if we're including something
        if [ ! -z "$include" ] && [ -z "$(echo "$f" | grep -Ei "$include")" ]; then
            continue
        fi
        # Make sure we *don't* have a match if we're excluding
        if [ ! -z "$exclude" ] && [ ! -z "$(echo "$f" | grep -Ei "$exclude")" ]; then
            continue
        fi
        # We should have a match here - print it out
        echo "Copying $(basename "$f") to $(basename "$dest")..."
        cp "$f" "$dest"
    done
    # Restore the original CD
    cd "$PWD"
}

if [ -e "$DIR/OC" ]; then
    echo "Removing previously built drivers..."
    rm -rf "$DIR/OC"
fi

# << 'COMMENT'

temp=$(mktemp -d)

echo "Creating OC folder..."
mkdir "$DIR/OC"

# Time to clone and build - let's clone the UDK repo first, as all others need this - we need to touch the
# Build the .efi drivers and OC
clone_and_build "OpenCorePkg" "$oc_url" "$temp"

# Reveal the built folder if needed
if [ "$to_reveal" == "TRUE" ]; then
    open "$temp"
    read -p "Press [enter] to continue..."
fi

# Now we find all .efi, .plist, and .pdf files (excluding some unneeded ones) and copy them over
find_and_copy "$temp" "$DIR/OC" "*.efi" "release" "(DEBUG|NOOP|OUTPUT|IA32)"
find_and_copy "$temp" "$DIR/OC" "*.plist" "" "Info.plist"
find_and_copy "$temp" "$DIR/OC" "*.pdf" "(Configuration|Differences)" ""

# Clean up
rm -rf "$temp"

# COMMENT
if [ "$to_copy" != "TRUE" ]; then
    echo "Done."
    exit 0
fi

mounted=""
vol_name="EFI"
if [ "$target_disk" == "" ]; then
    # Check for an existing EFI/ESP
    efi=""
    if [ -d "/Volumes/EFI" ]; then
        efi="/Volumes/EFI"
    elif [ -d "/Volumes/ESP" ]; then
        efi="/Volumes/ESP"
    fi
else
    # Got the UUID, see if it's mounted
    vol_name="$(diskutil info "$target_disk" | grep -i "Volume Name:" | awk '{ $1=""; $2=""; print }' | sed 's/^[ \t]*//;s/[ \t]*$//')"
    efi="$(diskutil info "$target_disk" | grep -i "Mount Point:" | awk '{ $1=""; $2=""; print }' | sed 's/^[ \t]*//;s/[ \t]*$//')"
    if [ "$efi" == "" ]; then
        # Not mounted
        mounted="False"
        echo "$vol_name not mounted - mounting..."
        sudo diskutil mount "$target_disk"
        efi="$(diskutil info "$target_disk" | grep -i "Mount Point:" | awk '{ $1=""; $2=""; print }' | sed 's/^[ \t]*//;s/[ \t]*$//')"
    fi
    # One last check - if not mounted, we alert the user
    if [ "$efi" == "" ]; then
        echo "Failed to mount $vol_name."
        mounted=""
    fi
fi
# Check if it's OC - and if so, let's replace some stuff
if [ "$efi" != "" ]; then
    echo "Updating .efi files..."
    if [ -d "$efi/EFI/OC" ]; then
        if [ -e "$efi/EFI/OC/OpenCore.efi" ]; then
            echo "Updating OpenCore.efi..."
            cp "$DIR/OC/OpenCore.efi" "$efi/EFI/OC/OpenCore.efi"
        fi
        if [ -e "$efi/EFI/BOOT/BOOTx64.efi" ]; then
            echo "Verifying BOOTx64.efi..."
            cat "$efi/EFI/BOOT/BOOTx64.efi" | grep -i OpenCore 2>&1 >/dev/null
            if [ "$?" == "0" ]; then
                echo " - Belongs to OpenCore - updating..."
                cp "$DIR/OC/Bootstrap.efi" "$efi/EFI/BOOT/BOOTx64.efi"
            else
                echo " - Does not belong to OpenCore - skipping..."
            fi
        fi
        if [ -e "$efi/EFI/OC/Bootstrap/Bootstrap.efi" ]; then
            echo "Updating Bootstrap.efi..."
            cp "$DIR/OC/Bootstrap.efi" "$efi/EFI/OC/Bootstrap/Bootstrap.efi"
        fi
        if [ -d "$efi/EFI/OC/Drivers" ]; then
            echo "Updating efi drivers..."
            ls "$efi/EFI/OC/Drivers" | while read f; do
                if [ -e "$DIR/OC/$f" ]; then
                    echo " - Found $f, replacing..."
                    cp "$DIR/OC/$f" "$efi/EFI/OC/Drivers/$f"
                fi
            done
        fi
    fi
fi

if [ "$mounted" != "" ]; then
    echo "Unmounting $vol_name..."
    diskutil unmount "$target_disk"
fi
# All done
echo "Done."
