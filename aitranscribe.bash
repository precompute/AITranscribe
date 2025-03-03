#!/bin/bash

## *  License:
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3, or (at your option)
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

## * AITranscribe.bash : Transcribe via API and insert text
# This tool
# 1. records audio via pw-record (pipewire)
# 2. feeds it to ffmpeg to get a FLAC file
# 3. sends it to the Groq via curl
# 4. parses JSON with jq
# And then, depending on what you chose, it does one of the following
# 5. Copies it to the clipboard with xclip
# 5. Inserts it via xdotool
# And at last,
# 6. Sends notification via notify-send

# Usage: Invoke script and start speaking.  When done, choose an option.
## * Required Tools
# Requires the following tools:
# - xdotool
# - xclip
# - notify-send
# - ffmpeg
# - curl
# - pw-record
# - jq

## * Code
## ** Variables
## -------------- Get your key here https://console.groq.com/keys -------------- ##
GROQ_API_KEY="YOUR_API_KEY_HERE"
BASE_DIR="/tmp/transcribe"
OUTPUT_WAV="$BASE_DIR/temp_audio_$$.wav"
OUTPUT_FLAC="$BASE_DIR/temp_audio_$$.flac"

## ** Functions
mkdir -p "$BASE_DIR"

record_audio() {
    pw-record --media-type Audio --media-category Capture --rate 44100 --channels 1 --format s16 "$OUTPUT_WAV" 2>&1
    if [ $? -ne 0 ]; then
        echo "Error: pw-record failed."
        if ! command -v pw-record &> /dev/null; then
            echo "pw-record command not found.  Please ensure it is installed and in your PATH."
        fi
        exit 1
    fi
    echo "Successfully recorded audio to $OUTPUT_WAV"
}

convert_to_flac() {
    ffmpeg -i "$OUTPUT_WAV" -ar 16000 -ac 1 -map 0:a -c:a flac "$OUTPUT_FLAC" -y &> /dev/null
    if [ $? -ne 0 ]; then
        echo "Error: ffmpeg conversion failed."
        if ! command -v ffmpeg &> /dev/null; then
            echo "ffmpeg not found. Is it installed?"
        fi
        exit 1
    fi
    echo "Successfully converted to $OUTPUT_FLAC"
}

transcribe_audio() {
    local flac_file="$1"
    local response=$(curl -s -X POST \
                          "https://api.groq.com/openai/v1/audio/transcriptions" \
                          -H "Authorization: Bearer $GROQ_API_KEY" \
                          -H "Content-Type: multipart/form-data" \
                          -F file="@$flac_file" \
                          -F model="whisper-large-v3-turbo" \
                          -F temperature="0" \
                          -F response_format="json" \
                          -F language="en" \
                          --max-time 60
          )
    if [ $? -ne 0 ]; then
        echo "Error: curl request to Groq API failed."
        exit 1
    fi

    if [ -z "$response" ]; then
        echo "Error: Empty response from Groq API."
        exit 1
    fi

    local transcription=$(echo "$response" | jq -r '.text')

    if [ $? -ne 0 ] || [[ "$transcription" == "null" ]]; then
        echo "Error: Failed to parse transcription response from Groq API, or 'text' field missing."
        echo "Full Response:"
        echo "$response"
        exit 1
    fi

    echo "$transcription"
}

copy_to_clipboard() {
    local text="$1"
    if command -v xclip &> /dev/null; then
        echo "$text" | xclip -selection clipboard
    else
         echo "xclip not found.  Clipboard copy skipped."
    fi
}

insert_text_with_xdotool() {
    local text="$1"

    if command -v xdotool &> /dev/null; then
        xdotool windowminimize $(xdotool getactivewindow)
        xdotool type --clearmodifiers "$text"
    else
         echo "xdotool not found.  Text insertion skipped."
    fi
}

send_notification() {
    local text="$1"
    local truncated_text=$(echo "$text" | cut -c -100)$([ "${#text}" -gt 100 ] && echo "...")

    if command -v notify-send &> /dev/null; then
        notify-send "Transcription" "$truncated_text"
    else
         echo "notify-send not found.  Notification skipped."
    fi
}

process_audio() {
    local transcription="$1"
    local insert="$2"

    echo "Transcription: $transcription"

    if [[ "$insert" == "true" ]]; then
        insert_text_with_xdotool "$transcription"
    else
         copy_to_clipboard "$transcription"
    fi

    send_notification "$transcription"
}

kill_recording() {
    kill -KILL "$recording_pid" 2>/dev/null
}

cleanup() {
    rm "$OUTPUT_WAV"
    exit 0
}

## ** Record Audio
record_audio &
recording_pid=$!

read -n 1 -p "(q)uit / (c)opy / (i)nsert: " choice
printf "\n"

## ** Primary loop
while true; do
    case "$choice" in
        [iI]*)
            kill_recording
            convert_to_flac
            transcription=$(transcribe_audio "$OUTPUT_FLAC")
            read -rd '' transcription <<<"$transcription" || :
            process_audio "$transcription" "true"
            cleanup
            ;;
        [cC]*)
            kill_recording
            convert_to_flac
            transcription=$(transcribe_audio "$OUTPUT_FLAC")
            read -rd '' transcription <<<"$transcription" || :
            process_audio "$transcription" "false"
            cleanup
            ;;
        *)
            echo "Quitting without processing."
            kill_recording
            cleanup
            ;;
    esac
done

## Local Variables:
## outline-regexp: "## [*]+"
## eval: (outline-minor-mode t)
## End:
