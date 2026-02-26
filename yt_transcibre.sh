#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
# Note: You can change this to 'yt-dlp' if youtube-dl gives you speed/download errors.
YTDL_CMD="yt-dlp" 
AUDIO_FILE="downloaded_audio.mp3"
OUTPUT_FILE="transcription.txt"

# --- Input Validation ---
if [[ -z "$1" ]]; then
    echo "Usage: $0 <youtube_url>"
    exit 1
fi
YOUTUBE_URL="$1"

# --- Dependency Check ---
for cmd in $YTDL_CMD curl jq; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd is not installed."
        exit 1
    fi
done

# --- API Key Check ---
if [[ -z "${OPENAI_API_KEY}" ]]; then
    echo "Error: OPENAI_API_KEY environment variable not set."
    exit 1
fi

# --- 1. Download Audio ---
echo "⏳ Downloading audio from YouTube..."
# -x extracts audio, --audio-format ensures it's mp3, -o sets the output filename
$YTDL_CMD -x --audio-format mp3 -o "$AUDIO_FILE" "$YOUTUBE_URL"
echo "✅ Audio downloaded successfully."

# --- 2. Transcribe Audio ---
echo "⏳ Transcribing audio with OpenAI Whisper..."
RESPONSE=$(curl --silent --show-error --fail --request POST \
  --url https://api.openai.com/v1/audio/transcriptions \
  --header "Authorization: Bearer $OPENAI_API_KEY" \
  --header 'Content-Type: multipart/form-data' \
  --form file=@"$AUDIO_FILE" \
  --form model=whisper-1 \
  --form response_format=json \
  --form language=en)
echo "✅ Transcription completed."

# --- 3. Parse and Save ---
echo "⏳ Extracting text..."
# Parse the JSON response using jq and save the raw text
echo "$RESPONSE" | jq -r '.text // empty' > "$OUTPUT_FILE"

echo "🟢 Success! Transcription saved to $OUTPUT_FILE"
