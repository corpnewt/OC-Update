# OC-Update
Bash script to update OpenCore and some efi drivers

## Help Output

    usage: OC-Update.command [-h] [-c] [-b] [-o] [-f] [-l] [-r] [-g]
                         [-d DISK] [-e NAME] [-e NAME] [-e...]

    OC-Update - a bash script to update OpenCore and efi drivers

    optional arguments:
      -h, --help              show this help message and exit
      -c, --no-copy           don't copy results to target disk
      -b, --no-build          don't clone and build repos, use what's in the OC
                              folder already
      -o, --no-opencanopy     skip checking OpenCanopy Resources for changes
      -f, --force             force update OpenCanopy Resources - overrides -l
      -l, --list-changes      only list OpenCanopy changes, don't update files
      -r, --reveal            reveal the temp folder after building
      -g, --debug             build the debug version of OC
      -d DISK, --disk DISK    the mount point/identifier to target
      -e NAME, --exclude NAME regex to exclude matching file/folder names from
                              OpenCanopy Resources to update - can be used
                              more than once, case-insensitive
