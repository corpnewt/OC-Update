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
oc_binary_data_url="https://github.com/acidanthera/OcBinaryData"
to_copy="TRUE"
to_build="TRUE"
to_opencanopy="TRUE"
to_force="FALSE"
to_reveal="FALSE"
copy_zip="TRUE"

exclusions=()
target_disk="$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:boot-path | sed 's/.*GPT,\([^,]*\),.*/\1/')"

function print_help () {
    echo "usage: OC-Update.command [-h] [-c] [-b] [-o] [-f] [-l] [-r] [-g]"
    echo "                         [-d DISK] [-e NAME] [-e NAME] [-e...]"
    echo ""
    echo "OC-Update - a bash script to update OpenCore and efi drivers"
    echo ""
    echo "optional arguments:"
    echo "  -h, --help              show this help message and exit"
    echo "  -c, --no-copy           don't copy results to target disk"
    echo "  -b, --no-build          don't clone and build repos, use what's in the OC"
    echo "                          folder already"
    echo "  -o, --no-opencanopy     skip checking OpenCanopy Resources for changes"
    echo "  -f, --force             force update OpenCanopy Resources - overrides -l"
    echo "  -l, --list-changes      only list OpenCanopy changes, don't update files"
    echo "  -r, --reveal            reveal the temp folder after building"
    echo "  -i, --ia32              build IA32 (32-bit) instead of X64 (64-bit)"
    echo "  -g, --debug             build the debug version of OC and .efi drivers"
    echo "  -z, --no-zip            don't copy the OpenCore-[version]-[target].zip to"
    echo "                          the OC folder"
    echo "  -d DISK, --disk DISK    the mount point/identifier to target"
    echo "  -e NAME, --exclude NAME regex to exclude matching file/folder names from"
    echo "                          OpenCanopy Resources to update - can be used"
    echo "                          more than once, case-insensitive"
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) print_help; exit 0 ;;
        -c|--no-copy) to_copy="FALSE" ;;
        -b|--no-build) to_build="FALSE" ;;
        -o|--no-opencanopy) to_opencanopy="FALSE" ;;
        -f|--force) to_force="TRUE" ;;
        -l|--list-changes) to_list="TRUE" ;;
        -r|--reveal) to_reveal="TRUE" ;;
        -i|--ia32) ARCHS=IA32 ;;
        -g|--debug) TARGETS=DEBUG; RTARGETS=DEBUG ;;
        -z|--no-zip) copy_zip="FALSE" ;;
        -d|--disk) target_disk="$2"; shift ;;
        -e|--exclude) exclusions+=( "$2" ); shift ;;
        *) echo "Unknown parameter passed: $1"; print_help; exit 1 ;;
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
    local nobuild="$4"
    cd "$temp"
    echo "Cloning $url..."
    git clone "$url" && cd "$name"
    if [ -z "$nobuild" ]; then
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
    fi
}

function compare_path () {
    local path="${1%/}"; shift # The path to append to both prefixes to check
    local source="$1"; shift   # The source path prefix
    local dest="$1"; shift     # The destination path prefix
    local response="$1"; shift # LIST to only list, FORCE to replace even if it exist
    local indent="$1"; shift   # Prefix to indent with
    local exclude=("$@")       # An array of names to exclude - will be checked case-insensitively
    local to_skip="FALSE"
    echo "$indent""+ $(basename "$source/$path")..."
    ls "$source/$path" | while read f; do
        to_skip="FALSE"
        for e in "${exclude[@]}"; do
            if [ "$(echo "$f" | grep -Ei "$e")" ]; then
                to_skip="TRUE"
                break
            fi
        done
        # Skip if we're excluding it
        if [ "$to_skip" == "TRUE" ]; then
            prefix="-"
            if [ -d "$source/$path/$f" ]; then
                prefix="+"
            fi
            echo "$indent""  $prefix $f skipped per exclusions..."
            continue
        fi
        # Check if it already exists - and what type of responses
        if [ -d "$source/$path/$f" ]; then
            # echo "$indent"" - Found '$f' directory..."
            # Ensure the target has it if we need it
            if [ ! -d "$dest/$path/$f" ]; then
                if [ "$response" == "LIST" ]; then
                    echo "$indent""  +-> Missing $f..."
                else
                    echo "$indent""  +-> Copying $f to destination..."
                    cp -R "$source/$path/$f" "$dest/$path/$f"
                fi
            else
                compare_path "$path/$f" "$source" "$dest" "$response" "$indent  " "${exclude[@]}"
            fi
        else
            if [ ! -e "$dest/$path/$f" ] && [ "$response" == "LIST" ]; then
                echo "$indent""  --> Missing $f..."
            elif [ ! -e "$dest/$path/$f" ] || [ "$response" == "FORCE" ]; then
                echo "$indent""  --> Copying $f..."
                cp "$source/$path/$f" "$dest/$path/$f"
            fi
        fi
    done
}

function find_and_copy () {
    local source="$1"
    local dest="$2"
    local name="$3"
    local args="$4"
    local include="$5"
    local exclude="$6"
    local dir="$PWD"
    cd "$source"
    find . -name "$name" $(echo $args) | while read f; do
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

# Time to clone and build - let's clone the UDK repo first, as all others need this - we need to touch the
# Build the .efi drivers and OC
if [ "$to_build" != "FALSE" ]; then
    if [ -e "$DIR/OC" ]; then
        echo "Removing previously built drivers..."
        rm -rf "$DIR/OC"
    fi

    # << 'COMMENT'

    temp=$(mktemp -d)

    echo "Creating OC folder..."
    mkdir "$DIR/OC"
    clone_and_build "OpenCorePkg" "$oc_url" "$temp"
    clone_and_build "OcBinaryData" "$oc_binary_data_url" "$temp" "nobuild"

    # Reveal the built folder if needed
    if [ "$to_reveal" == "TRUE" ]; then
        open "$temp"
        read -p "Press [enter] to continue..."
    fi

    # Copy the final zip over unless told not to
    zip_path="$(find "$temp/OpenCorePkg/Binaries" -name "OpenCore*$TARGETS.zip" -type f -maxdepth 1 | sed -n 1p)"
    if [ "$copy_zip" == "TRUE" ] && [ -f "$zip_path" ]; then
        echo "Copying $(basename "$zip_path") to OC folder..."
        cp "$zip_path" "$DIR/OC"
    fi

    # Clean out the Utilities folder - if it exists
    utils_dir="$temp/OpenCorePkg/Utilities"
    if [ -d "$utils_dir" ]; then
        echo "Pruning Utilities folder..."
        # Clear nested directories
        find "$utils_dir" -type d -mindepth 2 -exec rm -rf {} + 2>/dev/null
        # Strip source and unneeded files
        find "$utils_dir" -type f -maxdepth 2 | grep -E "(?i).*(test.*|\.c|\.h|make(file)?|license)$" | while read line; do rm "$line"; done; 2>/dev/null
        # Clear empty directories
        find "$utils_dir" -type d -empty -exec rm -rf {} + 2>/dev/null
        echo "Copying Utilities to OC folder..."
        cp -R "$utils_dir" "$DIR/OC/Utilities"
    fi    

    # Copy over the Docs folder
    docs_dir="$temp/OpenCorePkg/Docs"
    if [ -d "$docs_dir" ]; then
        echo "Copying Docs to OC folder..."
        cp -R "$docs_dir" "$DIR/OC/Docs"
    fi
    
    # Get the build directory - release is typically RELEASE_XCODE5
    build_dir="$(find "$temp/OpenCorePkg/UDK/Build/OpenCorePkg" -name ""$TARGETS"_XCODE*" -type d -maxdepth 1 | sed -n 1p)" 2>/dev/null
    if [ ! -z "$build_dir" ] && [ -d "$build_dir/$ARCHS" ]; then
        # Now we find all .efi drivers and copy them over
        args="-name "*.efi" -maxdepth 1"
        find_and_copy "$build_dir/$ARCHS" "$DIR/OC" "*.efi" "-maxdepth 1"
        # Special check for the Shell.efi file - as it gets renamed to OpenShell.efi in build_oc.tool
        if [ -e "$DIR/OC/Shell.efi" ]; then
            echo "Copying Shell.efi to OpenShell.efi in OC folder..."
            cp "$DIR/OC/Shell.efi" "$DIR/OC/OpenShell.efi"
        fi
    fi

    # Gather any .efi drivers from OcBinaryData
    if [ -d "$temp/OcBinaryData/Drivers" ]; then
        find_and_copy "$temp/OcBinaryData/Drivers" "$DIR/OC" "*.efi"
    fi

    # Let's copy the Resources folder over too
    if [ -d "$temp/OcBinaryData/Resources" ]; then
        echo "Copying OcBinaryData/Resources to OC folder..."
        cp -R "$temp/OcBinaryData/Resources" "$DIR/OC/Resources"
    fi

    # Clean up
    rm -rf "$temp"

    # COMMENT
fi

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
        if [ -e "$DIR/OC/OpenCore.efi" ] && [ -e "$efi/EFI/OC/OpenCore.efi" ]; then
            echo "Updating OpenCore.efi..."
            cp "$DIR/OC/OpenCore.efi" "$efi/EFI/OC/OpenCore.efi"
        fi
        if [ -e "$DIR/OC/Bootstrap.efi" ] && [ -e "$efi/EFI/BOOT/BOOTx64.efi" ]; then
            echo "Verifying BOOTx64.efi..."
            grep -i OpenCore "$efi/EFI/BOOT/BOOTx64.efi" 2>&1 >/dev/null
            if [ "$?" == "0" ]; then
                echo " - Belongs to OpenCore - updating..."
                cp "$DIR/OC/Bootstrap.efi" "$efi/EFI/BOOT/BOOTx64.efi"
            else
                echo " - Does not belong to OpenCore - skipping..."
            fi
        fi
        if [ -e "$DIR/OC/Bootstrap.efi" ] && [ -e "$efi/EFI/OC/Bootstrap/Bootstrap.efi" ]; then
            echo "Updating Bootstrap.efi..."
            cp "$DIR/OC/Bootstrap.efi" "$efi/EFI/OC/Bootstrap/Bootstrap.efi"
        fi
        if [ -d "$efi/EFI/OC/Drivers" ]; then
            echo "Updating .efi drivers..."
            ls "$efi/EFI/OC/Drivers" | while read f; do
                if [ -e "$DIR/OC/$f" ]; then
                    echo " - Found $f, replacing..."
                    cp "$DIR/OC/$f" "$efi/EFI/OC/Drivers/$f"
                fi
            done
        fi
    fi
    if [ "$to_opencanopy" != "FALSE" ] && [ -d "$DIR/OC/Resources" ]; then
        echo "Walking OpenCanopy Resources..."
        if [ "$to_force" == "TRUE" ]; then
            response="FORCE"
        elif [ "$to_list" == "TRUE" ]; then
            response="LIST"
        else
            response=""
        fi
        compare_path "" "$DIR/OC/Resources" "$efi/EFI/OC/Resources" "$response" "  " "${exclusions[@]}"
    fi
fi

if [ "$mounted" != "" ]; then
    echo "Unmounting $vol_name..."
    diskutil unmount "$target_disk"
fi
# All done
echo "Done."
