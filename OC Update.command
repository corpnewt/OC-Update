#!/usr/bin/env bash

clear

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

oc_url="https://github.com/acidanthera/OpenCorePkg"
# aptio_url="https://github.com/acidanthera/AptioFixPkg"
apple_url="https://github.com/acidanthera/AppleSupportPkg"
ocshell_url="https://github.com/acidanthera/OpenCoreShell"
to_copy="TRUE"
if [ "$1" == "-nocopy" ]; then
    echo "-- Only Building - WILL NOT Copy to ESP --"
    to_copy="FALSE"
fi

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
    ./macbuild.tool
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
# UDK.ready file to avoid the folder getting removed
cd "$temp" && git clone "https://github.com/acidanthera/audk" -b master --depth=1 UDK && cd UDK && touch UDK.ready
# Build the .efi drivers and OC
clone_and_build "OpenCorePkg" "$oc_url" "$temp"
# clone_and_build "AptioFixPkg" "$aptio_url" "$temp"
clone_and_build "AppleSupportPkg" "$apple_url" "$temp"
clone_and_build "OpenCoreShell" "$ocshell_url" "$temp"

# Now we find all the .efi files and copy them to the OC folder
cd "$temp"
find . -name '*.efi' | grep -Eiv "(DEBUG|NOOP|OUTPUT|IA32)" | grep -i release | while read f; do
    name="$(basename "$f")"
    echo "Copying $name to local OC folder..."
    cp "$f" "$DIR/OC"
done

# Clean up
rm -rf "$temp"

# COMMENT
if [ "$to_copy" != "TRUE" ]; then
    echo "Done."
    exit 0
fi

# Check for OC's UUID
uuid="$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path | sed 's/.*GPT,\([^,]*\),.*/\1/')"
mounted=""
vol_name="EFI"
if [ "$uuid" == "" ]; then
    # Check for an existing EFI/ESP
    efi=""
    if [ -d "/Volumes/EFI" ]; then
        efi="/Volumes/EFI"
    elif [ -d "/Volumes/ESP" ]; then
        efi="/Volumes/ESP"
    fi
else
    # Got the UUID, see if it's mounted
    vol_name="$(diskutil info $uuid | grep -i "Volume Name:" | awk '{ $1=""; $2=""; print }' | sed 's/^[ \t]*//;s/[ \t]*$//')"
    efi="$(diskutil info $uuid | grep -i "Mount Point:" | awk '{ $1=""; $2=""; print }' | sed 's/^[ \t]*//;s/[ \t]*$//')"
    if [ "$efi" == "" ]; then
        # Not mounted
        mounted="False"
        echo "$vol_name not mounted - mounting..."
        sudo diskutil mount "$uuid"
        efi="$(diskutil info $uuid | grep -i "Mount Point:" | awk '{ $1=""; $2=""; print }' | sed 's/^[ \t]*//;s/[ \t]*$//')"
    fi
    # One last check - if not mounted, we alert the user
    if [ "$efi" == "" ]; then
        echo "Failed to mount $vol_name."
        mounted=""
    fi
fi
# Check if it's OC - and if so, let's replace some stuff
if [ "$efi" != "" ]; then
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
                cp "$DIR/OC/BOOTx64.efi" "$efi/EFI/BOOT/BOOTx64.efi"
            else
                echo " - Does not belong to OpenCore - skipping..."
            fi
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
    diskutil unmount "$uuid"
fi
# All done
echo "Done."
