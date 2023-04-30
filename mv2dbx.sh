#!/usr/bin/env bash
#
# Move To Dropbox (mv2dbx)
#
# Copyright (C) 2023 Justin Henderson <justin@cosmicinbox.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
#

# Relies on dropbox_uploader.sh from Andrea Fabrizi <andrea.fabrizi@gmail.com>, 
# forked at https://github.com/electricalslice/dbxcli 

# Check the shell to ensure it is BASH
if [ -z "$BASH_VERSION" ]; then
  echo -ne "Error: this script requires the BASH shell!\n"
  exit 1
fi

# Default configuration file if no argument supplied
DEFAULT_CONFIG_FILE=/etc/mv2dbx.conf

# Considers the first and only argument as a config file.
if [ "$#" -eq 1 ]; then
  CONFIG_FILE=$1
else
  CONFIG_FILE=$DEFAULT_CONFIG_FILE
fi

#
# Parse the configuration file
#
parse_config() {
  # check if config file exists
  if [ -f $CONFIG_FILE ]; then
    # read config values not related to monitor filetypes
    while IFS= read -r line; do
      export "${line%%=*}"=${line#*=}
    done < <(grep -E "^[a-zA-Z].+=.+" "$CONFIG_FILE" | grep -v MV2DBX_SOURCE_FILETYPE)

    # read config values for any specified monitor filetypes
    i=0
    while IFS= read -r line; do
      export SOURCE_FILETYPE$i=${line#*=}
      ((i+=1))
    done < <(grep -E "^[a-zA-Z].+=.+" "$CONFIG_FILE" | grep MV2DBX_SOURCE_FILETYPE)

  else
    # config file does not exist
    echo -ne "Error: config file not found.\n"
    echo -ne "Error: config file ${CONFIG_FILE} not found. script: $0\n"
    exit 1
  fi

  # Verify required variables are defined
  if [[ -z "${MV2DBX_SOURCE_DIR}" ]]; then
    echo -ne "MV2DBX_SOURCE_DIR must be defined in config file. ex MV2DBX_SOURCE_DIR=/srv/ftp/foo\n"
    exit 1
  fi
  if [[ -z "${MV2DBX_TMP_DIR}" ]]; then
    echo -ne "MV2DBX_TMP_DIR must be defined in config file. ex MV2DBX_TMP_DIR=/dev/shm\n"
    exit 1
  fi

  # point to dropbox_uploader.sh
  if [[ -z "${MV2DBX_PATH_TO_UPLOADER}" ]]; then
    echo -ne "MV2DBX_PATH_TO_UPLOADER must be defined in config file. ex MV2DBX_PATH_TO_UPLOADER=./dropbox_uploader.sh\n"
    exit 1
  else
    #Checking if the file exists
    if [[ ! -e $MV2DBX_PATH_TO_UPLOADER ]]; then
      echo " > No such file: $MV2DBX_PATH_TO_UPLOADER"
      exit 1
    fi
  fi

  # for each provided filetype to upload, we want to form the args either 
  # as include switch for inotifywatch
  # or find cmd, ex find /srv/ftp/reo -type f -name "*.mp4"
  i=0
  name=SOURCE_FILETYPE$i
  if [[ -z "${!name}" ]]; then
    # If there are no filetypes specified
    include_arg=""
    MV2DBX_DELETE_SRCFILE=false
  else
    # There were filetypes specified so prefix the one time or monitor args
    include_arg="--include "
    name_arg=" "
  fi

  while :
  do
    if [[ -z "${!name}" ]]; then
        break;
    fi

    include_arg+="\\."${!name}""
    name_arg+="-name *."${!name}" "
    existing_files=$(find $MV2DBX_SOURCE_DIR -name "*\\."${!name}"" )

    ((i+=1))
    # if there is another filetype, add a | otherwise nothing
    name=SOURCE_FILETYPE$i
    if [[ -z "${!name}" ]]; then
      include_arg+=""
      name_arg+=""
    else
      include_arg+="|"
      name_arg+="-o "
    fi
  done


  # runs as a file/directory monitor by default. If run as user, runs one time,
  # unless MV2DBX_RUN_AS_MONITOR is true.
  if [ "$EUID" -ne 0 ]; then
    echo -ne "Detected running as a user, checking MV2DBX_RUN_AS_MONITOR... "
    if [ "$MV2DBX_RUN_AS_MONITOR" == true ]; then
      export EXEC_AS_MONITOR=1
      echo -ne "Running as a new file monitor.\n"
    else
      export EXEC_AS_MONITOR=0
      echo -ne "Running as a one time script.\n"
    fi
  else
    export EXEC_AS_MONITOR=1
  fi

  # if config entry MV2DBX_HANDLE_EXISTING is not found, make it default to false
  if [ ! -v MV2DBX_HANDLE_EXISTING ]; then
    MV2DBX_HANDLE_EXISTING=false
  fi
}

#Query the sha256-dropbox-sum of a local file
#see https://www.dropbox.com/developers/reference/content-hash for more information
#$1 = Local file
sha_local() {
  local file file_size offset skip sha_concat sha sha_hex
  file_size=$(stat --format="%s" "$1" 2>/dev/null)
  offset=0
  skip=0
  sha_concat=""

  which shasum >/dev/null
  if [[ $? -ne 0 ]]; then
    echo "ERR"
    return 1
  fi

  while [[ $offset -lt "$file_size" ]]; do
    dd if="$1" of="$MV2DBX_TMP_DIR/chunk" bs=4194304 skip=$skip count=1 2>/dev/null
    sha=$(shasum -a 256 "$MV2DBX_TMP_DIR/chunk" | awk '{print $1}')
    sha_concat="${sha_concat}${sha}"

    ((offset = offset + 4194304))
    ((skip = skip + 1))
  done

  if [[ "$(uname -s)" == "Darwin" ]]; then
    # sed for macOS will give an error "bad flag in substitute command: 'I'"
    # when using the original syntax. This option works instead.
    sha_hex=$(echo "$sha_concat" | sed 's/\([0-9A-Fa-f]\{2\}\)/\\x\1/g')
  else
    sha_hex=$(echo "$sha_concat" | sed 's/\([0-9A-F]\{2\}\)/\\x\1/gI')
  fi

  echo -ne "$sha_hex" | shasum -a 256 | awk '{print $1}'
}

# monitor a specified directory for new, closed, files. inotifywatch will inform
# when a new file is closed and action can be taken.
# see https://unix.stackexchange.com/questions/323901
do_monitor() {    
  echo -ne "Watching $MV2DBX_SOURCE_DIR for file changes...\n"

  # Be careful not to confuse the output of `inotifywait` with that of `echo`.
  # e.g. missing a `\` would break the pipe and write inotifywait's output, not
  # the echo's.
  inotifywait \
    $MV2DBX_SOURCE_DIR \
    $include_arg \
    --monitor \
    --timefmt '%Y-%m-%d-T%H:%M:%S' \
    --format '%T %w %f %e' \
    -e close_write \
  | while read datetime dir filename event; do
    # grab date info se we can upload to subfolders
    year=$( date "+%Y" )
    month=$( date "+%m" )
    day=$( date "+%d" )
    # upload new file to dropbox
    $MV2DBX_PATH_TO_UPLOADER -f $CONFIG_FILE -t $MV2DBX_TMP_DIR upload $dir$filename ./$year/$month/$day/

    # calculate shasum for newly uploaded file
    res1=$( $MV2DBX_PATH_TO_UPLOADER -f $CONFIG_FILE -t $MV2DBX_TMP_DIR sha $year/$month/$day/$filename )
    echo res1=$res1

    # calculate checksum for local file
    res2=$( sha_local $dir$filename )

    # compare remote shasum with local
    if [[ $res1 == $res2 ]]; then
      # delete local file if config dictates
      if [ $MV2DBX_DELETE_SRCFILE == true ]; then
        echo "Deleting source file $dir$filename"
        rm $dir$filename
      fi
    else
      echo "File was uploaded but file hashes do not match!"
    fi
  done
}

# search a specified directory for files to upload to dropbox and do so.
do_oneshot() {

  if [ ! -v name_arg ]; then
    file_arg="-type f"
  else
    file_arg="-type f "\(" $name_arg "\)
  fi

  find \
    $MV2DBX_SOURCE_DIR \
    $file_arg \
  | while read fn; do

    # grab date info se we can upload to subfolders
    year=$( date "+%Y" )
    month=$( date "+%m" )
    day=$( date "+%d" )

    # upload file to dropbox
    $MV2DBX_PATH_TO_UPLOADER -f $CONFIG_FILE -t $MV2DBX_TMP_DIR upload $fn ./$year/$month/$day/

    base_name=$(basename ${fn})
    
    # calculate checksum for newly uploaded file
    res1=$( $MV2DBX_PATH_TO_UPLOADER -f $CONFIG_FILE -t $MV2DBX_TMP_DIR sha $year/$month/$day/$base_name )
    echo res1=$res1

    # calculate checksum for local file
    res2=$( sha_local $fn )

    # compare remote shasum with local
    if [[ $res1 == $res2 ]]; then
      # delete local file if config dictates
      if [ $MV2DBX_DELETE_SRCFILE == true ]; then
        echo "Deleting source file $fn"
        rm $fn
      fi
    else
      echo "File was uploaded but file hashes do not match!"
    fi
  done
}

# Parse the config file
parse_config

# Determine if script is executed as a one-time run or a continuous monitor.
if [ $EXEC_AS_MONITOR -eq 1 ]; then
    # before going to monitor mode, upload existing files
    if [ $MV2DBX_HANDLE_EXISTING == true ]; then
        do_oneshot
    fi
    do_monitor
else
    do_oneshot
fi