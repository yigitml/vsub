#!/bin/bash

set -e

ACCELERATION=3.0
MAX_DURATION=320
SUBTITLE_ID_OFFSET=73

for cmd in ffmpeg curl jq bc; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd not installed."
        exit 1
    fi
done

if [[ -z "${OPENAI_API_KEY}" ]]; then
    echo "Error: OPENAI_API_KEY environment variable not set."
    exit 1
fi

echo "⏳ Extracting and accelerating audio from normal.mp4..."
ffmpeg -y -i normal.mp4 -q:a 0 -map a -filter:a "atempo=${ACCELERATION}" sound_acc.mp3
echo "✅ Audio processed successfully."

ACC_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 sound_acc.mp3)
echo "Accelerated duration: $ACC_DURATION seconds"

if (( $(echo "$ACC_DURATION > $MAX_DURATION" | bc -l) )); then
    SPLIT_POINT=$(awk "BEGIN {printf \"%.2f\", $MAX_DURATION / $ACCELERATION}")
    SPLIT_POINT_HMS=$(printf "%02d:%02d:%02d" $((${SPLIT_POINT%.*}/3600)) $((${SPLIT_POINT%.*}%3600/60)) $((${SPLIT_POINT%.*}%60)))
    
    echo "⏳ Splitting audio at $SPLIT_POINT_HMS..."
    ffmpeg -y -i sound_acc.mp3 -t "$SPLIT_POINT_HMS" -c copy part1.mp3
    ffmpeg -y -i sound_acc.mp3 -ss "$SPLIT_POINT_HMS" -c copy part2.mp3
    echo "✅ Audio split successfully."
else
    echo "Audio is short enough, no splitting needed."
    cp sound_acc.mp3 part1.mp3
    SPLIT_POINT=0
fi

transcribe_audio() {
    local file=$1
    curl --silent --show-error --fail --request POST \
      --url https://api.openai.com/v1/audio/transcriptions \
      --header "Authorization: Bearer $OPENAI_API_KEY" \
      --header 'Content-Type: multipart/form-data' \
      --form file=@"$file" \
      --form model=whisper-1 \
      --form response_format=verbose_json \
      --form language=de
}

echo "⏳ Transcribing part1..."
RESPONSE1=$(transcribe_audio part1.mp3)
echo "✅ Part1 transcribed successfully."

if [ -f part2.mp3 ]; then
    echo "⏳ Transcribing part2..."
    RESPONSE2=$(transcribe_audio part2.mp3)
    echo "✅ Part2 transcribed successfully."
else
    RESPONSE2='{"segments":[],"text":""}'
fi

echo "⏳ Combining transcriptions..."
echo -e "$(echo "$RESPONSE1" | jq -r '.text // empty')\n\n$(echo "$RESPONSE2" | jq -r '.text // empty')" > transkription.txt

echo "⏳ Creating subtitles..."
{
    echo "$RESPONSE1" | jq --argjson acc "$ACCELERATION" -r '
      .segments[] |
        (.id+1 | tostring) + "\n" +
        ((.start * $acc) | tonumber | strftime("%H:%M:%S,000")) + " --> " +
        ((.end * $acc) | tonumber | strftime("%H:%M:%S,000")) + "\n" +
        .text + "\n"'
    
    if [[ "$RESPONSE2" != '{"segments":[],"text":""}' ]]; then
        echo "$RESPONSE2" | jq --argjson acc "$ACCELERATION" --argjson split "$SPLIT_POINT" --argjson offset "$SUBTITLE_ID_OFFSET" -r '
          .segments[] |
            ((.id + $offset + 1) | tostring) + "\n" +
            (((.start + $split) * $acc) | tonumber | strftime("%H:%M:%S,000")) + " --> " +
            (((.end + $split) * $acc) | tonumber | strftime("%H:%M:%S,000")) + "\n" +
            .text + "\n"'
    fi
} > subtitles.srt
echo "✅ Subtitles created successfully."

echo "⏳ Burning subtitles into video..."
ffmpeg -y -i normal.mp4 -vf subtitles=subtitles.srt untertitled.mp4
echo "✅ Subtitles burned successfully."

echo "⏳ Translating to Turkish..."
TRANSLATION_RESPONSE=$(curl --silent --show-error --fail --request POST \
  --url https://api.openai.com/v1/chat/completions \
  --header "Authorization: Bearer $OPENAI_API_KEY" \
  --header "Content-Type: application/json" \
  --data @- <<EOF
{
  "model": "gpt-4o-mini",
  "messages": [
    {"role": "system", "content": "You are a professional German to Turkish translator."},
    {"role": "user", "content": $(jq -Rs '.' < transkription.txt)}
  ]
}
EOF
)

echo "$TRANSLATION_RESPONSE" | jq -r '.choices[0].message.content' > translation.txt
echo "✅ Translation completed successfully."

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_DIR="./Neues Video_${TIMESTAMP}"
mkdir -p "${OUTPUT_DIR}/tmp"

echo "⏳ Organizing files..."
find . -maxdepth 1 -name "*.mp3" -o -name "subtitles.srt" | xargs -I {} mv {} "${OUTPUT_DIR}/tmp/"

mv normal.mp4 untertitled.mp4 transkription.txt translation.txt "${OUTPUT_DIR}/"

echo "🟢 All files organized in ${OUTPUT_DIR}!" 