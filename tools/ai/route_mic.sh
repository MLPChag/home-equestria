#!/usr/bin/env bash
# Attach the game's PipeWire recording stream to the wanted microphone source.
# Godot records from the system default source; on this desk that is the soundboard's
# virtual mic (silence), and in the headset the voice arrives on wivrn.source instead.
# Called by speech_input.gd after the mic stream starts:
#   tools/ai/route_mic.sh [source-name] [client-name]   defaults: wivrn.source, "Home: Equestria"
#
# `pactl move-source-output` reports success here but leaves the PipeWire graph untouched
# (the stream stays linked to the old source), so the links are rewired with pw-link.
set -u
WANT="${1:-wivrn.source}"
CLIENT="${2:-Home: Equestria}"

ports_of() { pw-link "$1" 2>/dev/null | sed "s|^|$1:|"; }

for _ in $(seq 1 40); do
  mapfile -t INPUTS < <(pw-link -i 2>/dev/null | grep -Fx -e "$CLIENT:input_FL" -e "$CLIENT:input_FR" -e "$CLIENT:input_MONO")
  if ((${#INPUTS[@]})); then
    mapfile -t OUTS < <(pw-link -o 2>/dev/null | grep -F "$WANT:")
    if ((${#OUTS[@]} == 0)); then
      echo "[route_mic] source $WANT has no capture port; stream left alone"; exit 1
    fi
    for in_port in "${INPUTS[@]}"; do
      # Drop whatever currently feeds this input, then link the wanted source.
      while read -r existing; do
        [[ -n "$existing" ]] && pw-link -d "$existing" "$in_port" 2>/dev/null
      done < <(pw-link -l 2>/dev/null | awk -v want="$in_port" '
        $0 == want {inside = 1; next}
        inside && /^[[:space:]]+\|<-/ {sub(/^[[:space:]]+\|<-[[:space:]]*/, ""); print; next}
        inside && /^[^[:space:]]/ {inside = 0}')
      # A mono source feeds both channels; a stereo one pairs by position.
      src="${OUTS[0]}"
      if ((${#OUTS[@]} > 1)); then
        case "$in_port" in
          *_FR) src="${OUTS[1]}" ;;
        esac
      fi
      pw-link "$src" "$in_port" 2>/dev/null
    done
    echo "[route_mic] $CLIENT mic <- $WANT"
    exit 0
  fi
  sleep 0.5
done
echo "[route_mic] no game recording stream found" && exit 1
